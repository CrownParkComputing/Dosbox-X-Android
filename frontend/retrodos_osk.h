/* retro-dosbox — on-screen keyboard. See retrodos_osk.cpp for why the
 * modifiers are sticky rather than held. */
#ifndef RETRODOS_OSK_H
#define RETRODOS_OSK_H

namespace retrodos {

/* Draws a keyboard docked to the bottom of the screen. Call between
 * ImGui::NewFrame() and ImGui::Render(). Keys are delivered as SDL scancodes
 * through retrodos_host_send_key, so DOS sees ordinary key presses. */
void osk_draw(float screen_w, float screen_h);

/* Must be called every frame, whether or not the keyboard is visible: a key is
 * held for a short interval after it is pressed, and its release is issued from
 * here. */
void osk_update(void);

/* Ctrl+Alt+Del as one action -- too many DOS installers need it. */
void osk_send_ctrl_alt_del(void);

} /* namespace retrodos */

#endif
