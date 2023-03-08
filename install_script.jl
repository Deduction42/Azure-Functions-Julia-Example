import Pkg
#Install PyCall with existing python distro
#ENV["PYTHON"] = "/usr/bin/python3.9"
#Pkg.add("PyCall")

#Install required packages

@info "Adding standard packages"

Pkg.add("HTTP")
Pkg.add("JSON3")
Pkg.add("CSV")
Pkg.add("DataFrames")
Pkg.add("PackageCompiler")

#Install custom packages
@info "Adding custom packages"
Pkg.develop(path=joinpath(@__DIR__, "AzureTools"))

@info "Initializing custom packages"
using AzureTools


#Precompile packages if startup time becomes too long; this is generally required for anything beyond really simple packages, even CSV.jl starts pushing these limits
@info "Compiling packages"
using PackageCompiler

#I wasn't able to get AzureTools.jl to properly precompile
pkgList = [:JSON3, :CSV, :DataFrames]
compilerFile = joinpath(@__DIR__, "server_setup.jl")
imagePath = joinpath(@__DIR__, "sys_server.so")
@time create_sysimage(pkgList, sysimage_path=imagePath, precompile_execution_file=compilerFile, cpu_target="generic")

