#!/bin/sh

sudo apt update -y

sudo apt install -y apt-utils unzip curl wget git build-essential libreadline-dev dialog libssl-dev m4

cd /tmp

# install Go

wget https://dl.google.com/go/go1.17.2.linux-arm64.tar.gz
tar -xvf go1.17.2.linux-arm64.tar.gz
mv go /usr/local
rm go1.17.2.linux-arm64.tar.gz

# install lua

sudo apt install lua5.1
sudo apt install liblua5.1-dev

# install LuaRocks

wget https://luarocks.org/releases/luarocks-3.7.0.tar.gz
tar zxpf luarocks-*
rm luarocks-3.7.0.tar.gz
cd luarocks-*
./configure --with-lua-include=/usr/local/include
make
sudo make install
cd ..
rm -rf luarocks-*

sudo mkdir -p /usr/local/lib/luarocks/rocks-5.1

# install luasocket

sudo luarocks install luasocket

# install nixio (the version on luarocks is broken - lovely)

git clone https://github.com/jangala-dev/nixio
cd nixio/
sudo luarocks make

cd ..

# install lumen

git clone https://github.com/xopxe/lumen
sudo cp -r lumen /usr/local/lib/lua/*/
rm -rf lumen

# install cqueues

sudo luarocks install cqueues

# install luaposix

sudo luarocks install luaposix

# install bit32

sudo luarocks install bit32

# install afghanistanyn/lua-epoll

git clone https://github.com/afghanistanyn/lua-epoll
cd lua-epoll/
make
sudo cp epoll.so /usr/local/lib/lua/5.1/epoll.so

# install cffi-lua

sudo apt install meson pkg-config cmake libffi-dev

git clone https://github.com/q66/cffi-lua
mkdir cffi-lua/build
cd cffi-lua/build
sudo meson .. -Dlua_version=5.1 --buildtype=release
sudo ninja all
sudo ninja test
sudo cp cffi.so /usr/local/lib/lua/5.1/cffi.so

exit 0