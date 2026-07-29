FROM golang:1.24-bookworm

ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64 \
    GO111MODULE=on

WORKDIR /build
ADD ./ ./

RUN go build -o /opt/feedback ./services/feedback/cmd/feedback

RUN groupadd feedback && useradd -g feedback feedback -d /home/feedback && \
    chown -R feedback:feedback /opt/feedback && chmod +x /opt/feedback

USER feedback
EXPOSE 8080
CMD ["/opt/feedback"]
