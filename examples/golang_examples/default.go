package main

import (
	"fmt"
	"sync"
	"time"
)

var wg sync.WaitGroup

type WorkerStruct struct {
	chan1 chan string
	chan2 chan string
	name  string
}

func main() {
	wg.Add(1)
	worker1 := WorkerStruct{
		chan1: make(chan string),
		chan2: make(chan string),
		name:  "John",
	}

	go handler(worker1)
	go worker(worker1, 1)
	go complete()

	wg.Wait()
}

func handler(worker WorkerStruct) {
	for {
		select {
		case msg := <-worker.chan1:
			fmt.Println(msg)
		case msg := <-worker.chan2:
			fmt.Println(msg)
		default:
			fmt.Println("Default")
			time.Sleep(time.Second * 1)
		}
	}
}

func worker(worker WorkerStruct, sleepTime int) {
	for {
		worker.chan1 <- fmt.Sprintf("messages from %s on channel 1", worker.name)
		worker.chan2 <- fmt.Sprintf("messages from %s on channel 2", worker.name)
		time.Sleep(time.Second * time.Duration(sleepTime))
	}
}

func complete() {
	time.Sleep(time.Second * 10)
	fmt.Println("Complete")
	wg.Done()
}
