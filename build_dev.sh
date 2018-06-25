# build dev version rancher server in mac without dapper to give CPU relief
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -i -tags k8s -ldflags "-X main.VERSION=master" -o package/rancher && docker build -f package/Dockerfile -t rancher/rancher:dev package
