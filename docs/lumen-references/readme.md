Description of the Sierra ($) Framework that Lumen is based on from: http://lua-users.org/lists/lua-l/2011-09/msg00240.html

>Next was Fabien Fleutot from Sierra Wireless. They make embedded
system monitoring equipment, for checking the performance and status
of things like wind turbines and street lights. The communication
between these in-the-field assets and the back-end monitoring systems
is usually via GPRS, so it's important for them to minimise bandwidth
usage, and they mostly have to rely on the assets to initiate outgoing
connections since their connections are often down or behind NAT.
Their monitoring devices run embedded Lua and make heavy use of
coroutines, with a nice IPC framework and scheduler. Fabien described
how this makes it easier for them to do in-field upgrades and quickly
adapt their products for new customers. They're planning to release
their framework as open source.


