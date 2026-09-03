# Pak N64 Runtime — standalone Makefile
#
# Builds boot.S + vi.c + si.c + pak_hal.c into a static archive
# that n64_build.sh links against.
#
# Requires mips-n64-gcc in PATH or N64_GCC env var.

N64_GCC ?= mips-n64-gcc
AR       := $(subst gcc,ar,$(N64_GCC))

CFLAGS := \
    -march=vr4300 -mabi=32 -mfix4300 \
    -O2 -G0 \
    -ffreestanding -nostdlib -nostdinc \
    -fno-exceptions -fno-asynchronous-unwind-tables \
    -fno-stack-protector \
    -I .

SRCS_C := vi.c si.c pak_hal.c
SRCS_S := boot.S
OBJS   := $(SRCS_C:.c=.o) $(SRCS_S:.S=.o)
LIB    := libpak_n64.a

.PHONY: all clean

all: $(LIB)

$(LIB): $(OBJS)
	$(AR) rcs $@ $^

%.o: %.c
	$(N64_GCC) $(CFLAGS) -c -o $@ $<

%.o: %.S
	$(N64_GCC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) $(LIB)
