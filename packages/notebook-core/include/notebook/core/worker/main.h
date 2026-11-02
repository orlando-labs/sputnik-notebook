#pragma once

namespace sputnik::notebook::worker {
// Internal worker process adapter. Owns its VM and uses inherited IPC handles;
// an application starts it through Process rather than invoking it in a UI.
int worker_main(int argc, char **argv);
}
