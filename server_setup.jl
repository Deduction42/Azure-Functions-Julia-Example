@info "Starting on $(Threads.nthreads()) threads"
@info "Loading core libraries..."
const IS_FUNCTION_APP = parse(Bool, lowercase(get(ENV, "IsFunctionApp", "True")))

using Dates; T0 = datetime2unix(now())
using Logging
using Serialization

using HTTP
using JSON3
using CSV
using DataFrames

@info "Loading custom libraries..."
import AzureTools


@info "Setting up handlers..."
# ========================================================================================================
# Key structs and their APIs
# ========================================================================================================

Base.@kwdef struct HandlerResponse{R,F}
    res :: R
    fwd :: F
end
handler_response(r::Any) = HandlerResponse(res=(body=r,), fwd=nothing)
handler_response(r::Any, fwd::Any) = HandlerResponse(res=(body=r,), fwd=fwd)


Base.@kwdef struct FunctionAppResponse{O,R}
    Outputs :: O
    Logs :: Vector{String}
    ReturnValue :: R
end
FunctionAppResponse(x::T, logs::Vector{String}) where T = FunctionAppResponse(T, Nothing)(x, logs, nothing)  


"""
Method that locks python-related code to run on one thread, and disables GC during python calls
This is done to prevent segfaults. Use the following pattern:

pylock() do
    <put your python-calling code here>
end
"""
const PYLOCK = ReentrantLock()
pylock(f::Function) = Base.lock(PYLOCK) do
    prev_gc = GC.enable(false)
    try 
        return f()
    finally
        GC.enable(prev_gc) # recover previous state
    end
end



# ========================================================================================================
# Blob handling tools from custom package AzureTools.jl
# ========================================================================================================
const MODEL_STORAGE = get(ENV, "AzureWebJobsStorage", "")

blob_definition(container::String, filename::String) = AzureTools.BlobDefinition(
    connectstr=MODEL_STORAGE, 
    container=container, 
    blob=filename
)

function read_csv_blob(container::String, filename::String)
    blobDef = blob_definition(container, filename)
    csvBin  = pylock() do
        AzureTools.read_blob(blobDef)
    end
    return DataFrame(CSV.File(IOBuffer(csvBin), dateformat=dateformat))
end

function write_csv_blob(container::String, modelname::String, data::DataFrame)
    blobDef = blob_definition(container, modelname)
    io = IOBuffer()
    CSV.write(io, data)
    return pylock() do
        AzureTools.write_blob(blobDef, take!(io))
    end
end


# ========================================================================================================
# Generic request handling tools 
# ========================================================================================================

"boiler plate for handling a post request (applicable to both HTTP and Queue triggers, extend 'get_inner_body' for more triggers)"
function post_handler(instructions::Function, request::HTTP.Request)
    logger = SimpleLogger(IOBuffer()) #Logger to catch any messages in memory
    @info "Recieved request"
    
    with_logger(logger) do
        postBody = try
            reqBody = JSON3.read(request.body)
            @info "Recieved: $(reqBody)"
            get_inner_body(reqBody)
        catch err
            @error "Invalid JSON body"
            return error_responder(err, logger, catch_backtrace())
        end
        @info "Processing $(postBody)\n with instructions: $(instructions)"

        try
            results = instructions(postBody) 
            return json_responder(results, logger)
        catch err
            return error_responder(err, logger, catch_backtrace())
        end
    end
end


"Strategy for retriving message contents (depending if it is a function app)"
get_inner_body(reqBody::JSON3.Object) = IS_FUNCTION_APP ? parse_data_body(reqBody["Data"]) : reqBody

"Parse inner body from an HTTP or Queue trigger (add more options to this function if neccessary)"
function parse_data_body(data::JSON3.Object) 
    if haskey(data, "req")
        return JSON3.read(data["req"]["Body"])
    elseif haskey(data, "msg")
        return JSON3.read(JSON3.read(data["msg"]))
    else 
        error("Data field must either have 'req' for HTTP triggers or 'msg' for Queue triggers")
    end
end

"Forwards a post request to the output (useful for writting an HTTP message body as a Queue message)"
function post_forward(request::HTTP.Request)
    logger = SimpleLogger(IOBuffer()) #Logger to catch any messages in memory
    @info "Forwarding request"
    
    with_logger(logger) do
        try
            reqBody  = JSON3.read(request.body)
            @info "Recieved: $(reqBody)"

            postBody = get_inner_body(reqBody)
            @info "Forwarding $(typeof(postBody)): $(postBody)"

            output = handler_response(postBody, postBody)
            return json_responder(output, logger)
        catch err
            return error_responder(err, logger, catch_backtrace())
        end
    end
end

"Creates a JSON Function App response from outputs and a logger"
function json_responder(output::HandlerResponse, logger::SimpleLogger)
    message = output_message(output, logger)
    return HTTP.Response(200, ["Content-Type"=> "application/json"], JSON3.write(message, allow_inf=true))
end

"Creates an error response for a Function app"
function error_responder(err::Exception, logger::SimpleLogger, backtr)
	io = Base.IOBuffer()

    #log the error backtrace
	showerror(io, err, backtr)
    fullmessage = String(take!(io))
    @error fullmessage

    #Get the short version of the error
    showerror(io, err)
    shortmessage = String(take!(io))
    close(io)

    message = output_message(handler_response(shortmessage), logger)

	return HTTP.Response(400, ["Content-Type"=> "application/json"], JSON3.write(message))

end

"Formats output and logger in the manner desired by Azure functions"
function output_message(output, logger::SimpleLogger)
    message = FunctionAppResponse(
        Outputs = output,
        Logs    = logvector(String(take!(logger.stream))),
        ReturnValue  = nothing
    )
    close(logger.stream)

    return message
end

"Translates Julia logs into a vector of logs in the desired Azure Functions format"
function logvector(logStr::String)
    logStr = replace(logStr, "\n│"=>"")
    logStr = replace(logStr, "\n└"=>"")
    return String.(split(logStr, "┌", keepempty=false))
end


# ==============================================================================
# Create and run the server
# ==============================================================================
@info "Registering endpoints..."
# Make a router and add routes for our endpoints.
r = HTTP.Router()

HTTP.register!(r, "POST", "/Http_WithReturn", post_forward)
HTTP.register!(r, "POST", "/Http_ToQueue",    post_forward)
HTTP.register!(r, "POST", "/Queue_Ingest",    post_forward)

#When using Docker, this should be done via command line
@info "Server starting up, elapsed time = $(round(datetime2unix(now())-T0, digits=1)) seconds..."

#HTTP.serve(r, "0.0.0.0", 8080)
