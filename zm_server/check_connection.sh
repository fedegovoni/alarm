#!/bin/bash

resping=`ping -c1 www.google.it`
if [[ ($resping == *routerlogin* || $resping == *192\.168\.0\.1*) && ! -f /home/fede/already_checked ]]; then
	echo metto a posto la rete resping = $resping
	sudo route add default gw 192.168.1.1
	sudo route del default gw 192.168.0.1
	> /home/fede/already_checked
elif [[ ($resping == *routerlogin* || $resping == *192\.168\.0\.1*) && -f /home/fede/already_checked ]]; then
	echo riavvio la rete
	sudo service networking restart
	sudo rm /home/fede/already_checked
else
	sudo rm /home/fede/already_checked
fi
