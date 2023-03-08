from azure.storage.blob import BlobServiceClient
from io import BytesIO, RawIOBase

class BlobContainer:
    def __init__(self, con_string, container):
        blob_service_client = BlobServiceClient.from_connection_string(con_string)
        self.container_client = blob_service_client.get_container_client(container)

    def read_blob(self, blob_name):
        blob = self.container_client.get_blob_client(blob_name)
        blob_byte = blob.download_blob().readall()
        return bytearray(blob_byte)

    def write_blob(self, blob_name, data, create_snapshot=False, overwrite=True):
        blob = self.container_client.get_blob_client(blob_name)
        blob.upload_blob(data, overwrite=overwrite)

        if create_snapshot:
            blob.create_snapshot()        
        return None
    
