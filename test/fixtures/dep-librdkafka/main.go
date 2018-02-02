package main

import (
	"fmt"

	"github.com/confluentinc/confluent-kafka-go/kafka"
)

func main() {
	fmt.Println(kafka.LibraryVersion)
}
