FROM mcr.microsoft.com/azure-functions/python:4-python3.9

#Install Clang compiler
RUN apt-get update && apt-get install -y\
    clang

#Direction for webjob scripts
ENV AzureWebJobsScriptRoot=/home/site/wwwroot \
    AzureFunctionsJobHost__Logging__Console__IsEnabled=true
EXPOSE 8080 80

#Copy local files into the docker /home/site/wwwroot, default place to look for function apps
COPY . /home/site/wwwroot

#Install Julia (wget will download it, but it's best to just have it locally)
#RUN wget https://julialang-s3.julialang.org/bin/linux/x64/1.8/julia-1.8.5-linux-x86_64.tar.gz
RUN mv /home/site/wwwroot/julia-1.8.5-linux-x86_64.tar.gz /
RUN tar zxvf julia-1.8.5-linux-x86_64.tar.gz
ENV PATH="${PATH}:/julia-1.8.5/bin"

#Install PyCall with Julia, pointing out where our current Python distro is located (can be found using >>RUN which python)
RUN julia -t auto -e "ENV[\"PYTHON\"]= \"/usr/local/bin/python\"; using Pkg; Pkg.add(\"PyCall\")"

#Install dependencies for both Python and Julia (now that everything is in /home/site/wwwroot)
WORKDIR /home/site/wwwroot
RUN pip install -r requirements.txt
RUN julia install_script.jl 

#Briefly run the server to trigger precompilation and speed up launch execution
RUN julia -t auto -- server_setup.jl

#Default startup command
WORKDIR /
#CMD julia -t auto -- /home/site/wwwroot/server_start.jl 
#CMD ["/home/site/wwwroot/azure-functions-host/Microsoft.Azure.WebJobs.Script.WebHost"]
