#ifndef PAK_SI_H
#define PAK_SI_H

#include <stdint.h>

/*
 * Controller state — field names match libdragon's joypad_buttons_t
 * so that Pak-generated code using pad.a / pad.stick_x etc. compiles.
 */
typedef struct {
    /* Face / system buttons */
    unsigned a      : 1;
    unsigned b      : 1;
    unsigned z      : 1;
    unsigned start  : 1;
    /* D-pad */
    unsigned up     : 1;
    unsigned down   : 1;
    unsigned left   : 1;
    unsigned right  : 1;
    /* Shoulder */
    unsigned l      : 1;
    unsigned r      : 1;
    /* C-buttons */
    unsigned c_up   : 1;
    unsigned c_down : 1;
    unsigned c_left : 1;
    unsigned c_right: 1;
    /* Padding to align */
    unsigned _pad   : 2;
    /* Analog stick  (-128 .. +127) */
    int8_t   stick_x;
    int8_t   stick_y;
} joypad_buttons_t;

void            si_init(void);
void            si_poll(void);
joypad_buttons_t si_read(int port);

#endif /* PAK_SI_H */
