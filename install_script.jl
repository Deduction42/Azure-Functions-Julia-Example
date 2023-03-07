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

pkgList = [:JSON3, :CSV, :DataFrames]

#Install custom packages
@info "Adding custom packages"
Pkg.develop(path=joinpath(@__DIR__, "MLAD3"))
Pkg.develop(path=joinpath(@__DIR__, "AzureTools"))

@info "Initializing custom packages"
using MLAD3
using AzureTools

push!(pkgList, :MLAD3)

@info "Compiling packages"
using PackageCompiler

compilerFile = joinpath(@__DIR__, "server_setup.jl")
imagePath = joinpath(@__DIR__, "sys_server.so")
@time create_sysimage(pkgList, sysimage_path=imagePath, precompile_execution_file=compilerFile, cpu_target = "generic")


#=
Packages to add for MLAD3
add LinearAlgebra
add Statistics
add Dates
add DataFrames
add CSV
add SparseArrays
add OffsetArrays
add Interpolations
add NaNStatistics
add StaticArrays
add Distributions
add LogExpFunctions
add JSON3
add NaNMath
=#

#=
Packages to add for AzureTools
add PyCall
=#