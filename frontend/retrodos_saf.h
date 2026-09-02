/*
 * retro-dosbox — Storage Access Framework bridge.
 *
 * SAF yields content:// URIs; DOSBox-X mounts a directory BY PATH. So the
 * library is ENUMERATED over SAF (names are all a launcher needs) and the one
 * game being launched is STAGED into the app's own directory, which is a real
 * path. See retrodos_saf.cpp. Stubs on non-Android, so callers need no #ifdef.
 */
#ifndef RETRODOS_SAF_H
#define RETRODOS_SAF_H

#include <string>
#include <vector>

namespace retrodos {

/* Opens the system folder picker. Returns immediately -- the grant arrives
 * asynchronously, so poll saf_has_grant(). */
void saf_pick_folder(void);

/* True once the user has granted a folder AND the grant is still live (it is
 * lost if the volume is reformatted). */
bool saf_has_grant(void);

std::string saf_tree_uri(void);

/* Sub-folder names of the granted tree: one per game. */
std::vector<std::string> saf_list_games(void);

/* Copy one game out of the tree into dest_dir (a real path). No-op when
 * dest_dir already holds files, so relaunching costs nothing. */
bool saf_stage_game(const std::string &name, const std::string &dest_dir);

/** Ask the user for one game file and install it into [dest_root]. Returns
 *  immediately; watch saf_install_status() for the outcome. */
void saf_pick_game(const std::string &dest_root);

/** Progress of the last saf_pick_game(), or empty when nothing is happening. */
std::string saf_install_status(void);

} /* namespace retrodos */

#endif
