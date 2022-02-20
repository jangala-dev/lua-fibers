// Taken from Googler Sameer Ajmani's talk _Advanced Go Concurrency Patterns_
// available at https://talks.golang.org/2013/advconc.slide#6 What's nice about
// this example is it's simplicity
package main

import (
	"fmt"
	"time"
)

func main() {
	var Ball int
	table := make(chan int)
	go player(table)
	go player(table)
	table <- Ball
	time.Sleep(1 * time.Second)
	<-table
}

func player(table chan int) {
	for {
		ball := <-table
		ball++
		fmt.Println("Ball value is now: ", ball)
		time.Sleep(100 * time.Millisecond)
		table <- ball
	}
}
