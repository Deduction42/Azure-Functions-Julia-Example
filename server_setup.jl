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
import MLAD3
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


const PYLOCK = ReentrantLock()

"""
Method that locks python-related code to run on one thread, and disables GC during python calls
This is done to prevent segfaults. Use the following pattern:

pylock() do
    <put your python-calling code here>
end
"""
pylock(f::Function) = Base.lock(PYLOCK) do
    prev_gc = GC.enable(false)
    try 
        return f()
    finally
        GC.enable(prev_gc) # recover previous state
    end
end

# ========================================================================================================
# Model Training
# ========================================================================================================


post_train_model(req::HTTP.Request) = post_handler(call_train_model, req)

function call_train_model(body::JSON3.Object)
    modelname = body[:model_name]
    dtformat  = DateFormat(get(body, :date_format, "yyyy-mm-ddTHH:MM:SS"))

    @info "Reading data for $(modelname)"
    settings = read_model_specs(modelname)
    data     = read_training_data(modelname, dateformat=dtformat)
    only_when_running!(data, settings)

    @info "Training model: $(modelname)"
    trained  = MLAD3.train_model(data, settings)

    @info "Writing model and metadata for $(modelname)"
    write_model_object(modelname, trained.model)
    write_model_state(modelname, trained.state)
    write_model_specs(modelname, trained.specs)

    return handler_response("successfully trained model: $(modelname)")
end



# ========================================================================================================
# Data handling tools
# ========================================================================================================
const MODEL_STORAGE = get(ENV, "ModelStorage", "")

"Use the 'off_conditions' field in the settings object to filter out data where asset is not running"
function only_when_running!(df::DataFrame, settings::JSON3.Object)
    offcond = settings[:off_conditions]
    tag = offcond[:tag]
    cutoff = offcond[:value]

    if lowercase(offcond[:relationship]) == "less than"
        return filter!(row-> cutoff < row[tag], df)
    elseif lowercase(offcond[:relationship]) == "greater than"
        return filter!(row-> cutoff > row[tag], df)
    else
        error("'on_conditions' field 'relationship' must be either 'greater than' or 'less than'")
    end
end

blobdef_model_object(modelname::String) = AzureTools.BlobDefinition(
    connectstr=MODEL_STORAGE, container="mlad-models", blob=modelname*".jls"
)
blobdef_model_state(modelname::String) = AzureTools.BlobDefinition(
    connectstr=MODEL_STORAGE, container="mlad-states", blob=modelname*".json"
)
blobdef_model_specs(modelname::String) = AzureTools.BlobDefinition(
    connectstr=MODEL_STORAGE, container="mlad-settings", blob=modelname*".json"
)
blobdef_training_data(modelname::String) = AzureTools.BlobDefinition(
    connectstr = MODEL_STORAGE, container="mlad-training", blob=modelname*".csv"
)

function read_model_object(modelname::String)
    modelDef = blobdef_model_object(modelname)
    return pylock() do
        deserialize(IOBuffer(AzureTools.read_blob(modelDef)))
    end
end

function write_model_object(modelname::String, obj)
    modelDef = blobdef_model_object(modelname)
    io = IOBuffer()
    serialize(io, obj)
    return pylock() do
        AzureTools.write_blob(modelDef, take!(io))
    end
end
    

function read_model_state(modelname::String)
    stateDef = blobdef_model_state(modelname)
    pylock() do
        return JSON3.read(AzureTools.read_blob(stateDef), allow_inf=true )
    end
end

function write_model_state(modelname::String, obj)
    stateDef = blobdef_model_state(modelname)
    io = IOBuffer()
    JSON3.pretty(io, obj, allow_inf=true)
    pylock() do
        return AzureTools.write_blob(stateDef, take!(io))
    end
end

function read_model_specs(modelname::String)
    specsDef = blobdef_model_specs(modelname)
    pylock() do
        return JSON3.read(AzureTools.read_blob(specsDef), allow_inf=true )
    end
end

function write_model_specs(modelname::String, obj)
    specDef = blobdef_model_specs(modelname)
    io = IOBuffer()
    JSON3.pretty(io, obj, allow_inf=true)
    pylock() do
        return AzureTools.write_blob(specDef, take!(io))
    end
end


function read_training_data(modelname::String; dateformat=dateformat"yyyy-mm-ddTHH:MM:SS")
    dataDef = blobdef_training_data(modelname)
    csvBin  = pylock() do
        AzureTools.read_blob(dataDef)
    end
    csvData = DataFrame(CSV.File(IOBuffer(csvBin), dateformat=dateformat))

    return handle_missing_values!(csvData)
end

function handle_missing_values!(df::DataFrame)
    dropmissing!(df, 1) #Remove rows where timestamp column is empty
    df .= coalesce.(df, NaN) #Set missing values to NaN
    disallowmissing!(df) #Remove typeunions from array types
    return df
end

function logvector(logStr::String)
    logStr = replace(logStr, "\n│"=>"")
    logStr = replace(logStr, "\n└"=>"")
    return String.(split(logStr, "┌", keepempty=false))
end



# ========================================================================================================
# Generic request handling tools 
# ========================================================================================================

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


function json_responder(output::HandlerResponse, logger::SimpleLogger)
    message = output_message(output, logger)
    return HTTP.Response(200, ["Content-Type"=> "application/json"], JSON3.write(message, allow_inf=true))
end

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
    #error(fullmessage)

	return HTTP.Response(200, ["Content-Type"=> "application/json"], JSON3.write(message))

end

function output_message(output, logger::SimpleLogger)
    message = FunctionAppResponse(
        Outputs = output,
        Logs    = logvector(String(take!(logger.stream))),
        ReturnValue  = nothing
    )
    close(logger.stream)

    return message
end





#=
function post_asset_survival_results(req::HTTP.Request)
	return post_handler(req, BRIE.asset_survival_results)
end

function post_asset_backfill_results(req::HTTP.Request)
	return post_handler(req, BRIE.asset_backfill_results)
end
=#

#=
#Test logger example
function log_test_function(x)
    for ii in 1:10
        xi = x*ii
        @info "the value is $(xi)"
    end
end

logger = Logging.SimpleLogger(IOBuffer())
with_logger(logger) do 
    log_test_function(2.6)
end
resp = String(take!(logger.stream))
close(logger.stream)
=#

# ==============================================================================
# Create and run the server
# ==============================================================================
@info "Registering endpoints..."
# Make a router and add routes for our endpoints.
r = HTTP.Router()

#HTTP.register!(r, "GET", "/version", version)

HTTP.register!(r, "POST", "/Http_TrainDirect", post_train_model)
#HTTP.register!(r, "POST", "/Http_TrainDirect", post_forward)

HTTP.register!(r, "POST", "/Http_TrainQueue",  post_forward)

HTTP.register!(r, "POST", "/Queue_Train",      post_train_model)
#HTTP.register!(r, "POST", "/Queue_Train",      post_forward)

#When using Docker, this should be done via command line
@info "Server starting up, elapsed time = $(round(datetime2unix(now())-T0, digits=1)) seconds..."

#HTTP.serve(r, "0.0.0.0", 8080)
