FROM golang:1.27-alpine

WORKDIR /app

COPY go.mod ./

RUN go mod download

COPY . .

RUN go build -o backend .

EXPOSE 8080

CMD ["./backend"]
