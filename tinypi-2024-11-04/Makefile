# TinyPI makefile

# 32 bit build
#CONFIG_32BIT=y
# add debug info
#CONFIG_DEBUG=y
# address sanitizer
#CONFIG_ASAN=y

CC=gcc
CFLAGS=-Wall -g
#CFLAGS+=-O2
CFLAGS+=-Os
LDFLAGS=-g $(PROFILE)
ifdef CONFIG_DEBUG
CFLAGS+=-Werror
LDFLAGS+=-g
else
LDFLAGS+=-s
endif

ifdef CONFIG_ASAN
CFLAGS+=-fsanitize=address
LDFLAGS+=-fsanitize=address
endif

ifdef CONFIG_32BIT
CFLAGS+=-m32
LDFLAGS+=-m32
endif

PROGS=tinypi

all: $(PROGS)

tinypi: tinypi.o
	$(CC) $(LDFLAGS) -o $@ $^ -lm
	@size tinypi.o

test: all
	time ./tinypi 1e5 /tmp/pi_1e5.txt
	time ./tinypi 1e6 /tmp/pi_1e6.txt
	time ./tinypi 1e7 /tmp/pi_1e7.txt
#	time ./tinypi 1e8 /tmp/pi_1e8.txt
	sha1sum -c pi.sha1sum

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(PROGS) *.o *~
