openssl genrsa -out server.key 1024
openssl req -new -key server.key -out server.csr
openssl x509 -req -in server.csr -out server.crt -signkey server.key -days 3650
