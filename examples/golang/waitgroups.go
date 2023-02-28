package main

import (
	"fmt"
	"sync"
	"time"
)

var num_routines = 1000

func main() {
	var wg1 sync.WaitGroup
	var wg2 sync.WaitGroup

	wg1.Add(1)
	go func() {
		time.Sleep(1 * time.Second)
		wg1.Done()
	}()

	for i := 1; i <= num_routines; i++ {
		wg2.Add(1)
		go func() {
			wg1.Wait()
			fmt.Println("goroutine", i, "leaving")
			time.Sleep(1 * time.Second)
			wg2.Done()
		}()
	}

	fmt.Println("Waiting")
	wg2.Wait()
	fmt.Println("OK")
}
