# build.jl — builds a system image with AktaPrime and its GUI already compiled,
# so the program starts in seconds and first clicks are instant.
#
#   julia --project=sysimage sysimage/build.jl      (takes 10–20 minutes)
#
# Rebuild after updating the code or packages; AktaPrime.sh starts without the
# image (and says so) when the code is newer than the image.

using Pkg
Pkg.instantiate()
using PackageCompiler

root = dirname(@__DIR__)
image = joinpath(@__DIR__, Sys.iswindows() ? "AktaPrime.dll" : Sys.isapple() ? "AktaPrime.dylib" : "AktaPrime.so")
create_sysimage(["AktaPrime"];
    project=root,
    sysimage_path=image,
    precompile_execution_file=joinpath(@__DIR__, "warmup.jl"))
@info "System image written to $image"
