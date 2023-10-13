CC=gcc
CFLAGS=-Wall -g

EXEUTABLES=ex1 ex3 ex4 ex5 ex6 ex17 ex18 ex20 ex22 ex23 argv malloc

all: $(EXEUTABLES)

ex22: ex22_main.c ex22.o
	$(CC) $(CFLAGS) $^ -o $@

clean:
	rm -rf $(EXEUTABLES)

