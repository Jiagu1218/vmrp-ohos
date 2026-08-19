/* tsf_impl.c - TinySoundFont + TinyMidiLoader implementation wrapper for OHOS/vmrp.
 *
 * #define TSF_IMPLEMENTATION / TML_IMPLEMENTATION produces the entire library
 * in one compilation unit.  Both NO_STDIO macros are defined because vmrp on
 * OHOS has no filesystem access from the native audio path; SF2 and MIDI data
 * will be loaded via tsf_load_memory() / tml_load_memory() from rawfile bytes
 * passed by the host.
 */
#define TSF_NO_STDIO
#define TML_NO_STDIO
#define TSF_IMPLEMENTATION
#define TML_IMPLEMENTATION
#include "tsf.h"
#include "tml.h"
