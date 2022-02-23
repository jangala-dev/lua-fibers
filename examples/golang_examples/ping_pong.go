// Taken from Googler Sameer Ajmani's talk _Advanced Go Concurrency Patterns_
// available at https://talks.golang.org/2013/advconc.slide#6 What's nice about
// this example is its simplicity
package main

import (
	"fmt"
	"time"
)

type Ball struct{ hits int }

func player(name string, table chan *Ball) {
	for {
		ball := <-table
		ball.hits++
		fmt.Println(name, ball.hits)
		time.Sleep(100 * time.Millisecond)
		table <- ball
	}
}

func main() {
	table := make(chan *Ball)
	go player("ping", table)
	go player("pong", table)
	table <- new(Ball) // game on; toss the ball
	time.Sleep(1 * time.Second)
	<-table // game over; grab the ball
}
