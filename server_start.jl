#const PORT = parse(Int64, get(ENV, "PORT", "8080"))
const PORT = parse(Int64, get(ENV, "FUNCTIONS_CUSTOMHANDLER_PORT", "8080"))

include(joinpath(@__DIR__, "server_setup.jl"))

HTTP.serve(r, "0.0.0.0", PORT)