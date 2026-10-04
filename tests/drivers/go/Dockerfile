FROM golang:1.21-alpine
WORKDIR /app
COPY go.mod main.go ./
RUN go mod tidy
RUN go build -o /app/tester main.go
CMD ["/app/tester"]
