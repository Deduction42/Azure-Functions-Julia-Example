using PyCall

const PyBlob = PyNULL()

function __init__()
    pushfirst!(pyimport("sys")."path", @__DIR__)
    copy!(PyBlob, pyimport("pyblob"))
end

Base.@kwdef struct BlobDefinition
    connectstr :: String
    container  :: String
    blob       :: String
end

function read_blob(blobdef::BlobDefinition)
    containerClient = PyBlob.BlobContainer(blobdef.connectstr, blobdef.container)
    return containerClient.read_blob(blobdef.blob)
end

function write_blob(blobdef::BlobDefinition, data; overwrite=true, create_snapshot=false)
    containerClient = PyBlob.BlobContainer(blobdef.connectstr, blobdef.container)
    containerClient.write_blob(
        blob_name = blobdef.blob, 
        data = data, 
        create_snapshot = create_snapshot, 
        overwrite = overwrite
    )
    return nothing
end 

function switch_blob(blobdef::BlobDefinition, blob::String)
    return BlobDefinition(
        connectstr = blobdef.connectstr,
        container  = blobdef.container,
        blob       = blob
    )
end










