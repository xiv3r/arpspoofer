# About 
arpspoofer is an arp spoofer tool based on arping that can spoof all the address resolution protocol of th entire networks.

# Platforms
- Debian and Arch based linux distros

# Auto install
```
sudo apt update && sudo apt install -y git && git clone https://github.com/xiv3r/arpspoofer.git && chmod 755 arpspoofer/spoof.sh && cd arpspoofer
```
# Usage
```
sudo bash spoof.sh
```
- Enter interface  = wlan0 or enter for auto detection 
- Enter Gateway IP = 10.0.0.1 or enter for auto detection
- Enter target IP  = 10.0.0.100 or scan the network using nmap
