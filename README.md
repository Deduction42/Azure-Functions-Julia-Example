# Azure-Functions-Julia-Example
Implements an example of a custom Azure Functions handler in Julia (similar to the Go example provided by Microsoft). This example constists of three major endpoints:

1. Http_WithReturn: A regular HTTP endpoint that returns a value
2. Http_ToQueue: Sends the body message to the queue ("orders") in the associated storage account
3. Queue_Ingest: Ingests message from queue ("orders")

Note that this project requires you to download julia for Linux as a .tar.gz file. You will need to modify the docker file to point to that Julia installation and add it to your environment path. You can uncomment the "RUN wget" command and run that, but that will download Julia every time you build the docker file. 

## Python
This project makes use of the Python base image from Azure and installs PyCall, to take advantage of it. This is done mostly to enable the convenient use of various Azure SDKs. Due to the inherent safety issues of calling Python in multithreaded envrionments, make sure you wrap any Python-dependent code in a `pylock() do` block with the `pylock` function provided. This is a workaround for a well-known PyCall issue in multighreaded environments. The `pylock` pattern enables single-threaded execution of python code and prevents garbage-collection calls from other threads which could randomly cause a segfault (https://github.com/JuliaPy/PyCall.jl/issues/1006). This requirement may be relaxed if the offending issue is fixed. An example is provided for blob storage (which is a particularly useful SDK), but you can expose more Python SDKs and package them into the local AzureTools.jl package if you like.

## Data parsing
Bodies from Http triggers and Queue triggers have different formats, but both messages live under Data. This server assumes (through `get_inner_body` and `parse_data_body`) that if `reqBody["Data"]` comes from an HTTP trigger, the corresponding field in "Data" will be "req" and if it comes from a Queue trigger, the corresponding field will by "msg". You may eventually want to use some other method to discriminate.

## Precompilation
I have found that for most non-trivial Julia function apps, startup time becomes a serious issue; apps tend to fail if they don't start up within one minute. To alleviate this, you may need to put your server code into "package format" as seen in AzureTools.jl and install the package using Pkg.develop (as seen in install_script.jl). Precompilation requires the Clang compiler (installed in the early portion of the docker file). Unfortunately, I was not able to successfully precompile AzureTools.jl, likely failing due to Python dependencies (potentially someone can contribute a fix) but since AzureTools.jl only contains a single PyCall dependency, it does not strongly affect startup times.


