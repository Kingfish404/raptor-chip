all:
	cc -c libex29.c -o libex29.o
	cc -shared -o libex29.so libex29.o
	cc -Wall -g -DNDEBUG ex29.c -ldl -o ex29

run: all
	./ex29 ./libex29.so print_a_message "Hello world!"
