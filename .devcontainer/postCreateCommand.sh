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

curl -R -O http://www.lua.org/ftp/lua-5.1.5.tar.gz
tar -zxf lua-*
rm lua-5.1.5.tar.gz
cd lua-*
make linux test
sudo make install
cd ..
rm -rf lua-*

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

git clone https://github.com/Neopallium/nixio
cd nixio/
sudo luarocks make

cd ..

# install lumen

git clone https://github.com/xopxe/lumen
sudo cp -r lumen /usr/local/lib/lua/*/

# install cqueues

sudo luarocks install cqueues

# install luaposix

sudo luarocks install luaposix

# install bit32

sudo luarocks install bit32

# install luatz

sudo luarocks install luatz

exit 0