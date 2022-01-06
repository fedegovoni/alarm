import sys
import os
import telepot
import datetime
import time
import urllib3
import io
import configparser
from PIL import Image
import requests
from io import BytesIO as ioBytes
import traceback

"""
Ctrl-C per uscire.
"""

http = urllib3.PoolManager
configParser = configparser.RawConfigParser()
configFilePath = r'./cameras.conf'
configParser.read(configFilePath)

cameraList = configParser['CAMERAS']
commandList = configParser['ZM_COMMANDS']
authorizedChatIds = configParser['TELEGRAM_AUTHORIZED_CHAT_IDS']['IDS']
botToken = configParser['TELEGRAM_BOT_TOKEN']['AUTH_TOKEN']
adminChatIds = configParser['TELEGRAM_ADMIN_CHAT_IDS']['IDS']


def handle(msg):
    chat_id = msg['chat']['id']
    command = msg['text']
    sender = str(msg['from']['id'])
    noermalizedCommand = command.upper()

    print('Got command: %s' % command)

    if sender in authorizedChatIds:
        if noermalizedCommand in cameraList:
            print("Ricevuto come Camera")
            url = cameraList[command]
            try:
                response = requests.get(url)
                bot.sendPhoto(chat_id=chat_id,
                              photo=io.BytesIO(response.content))
            except:
                traceback.print_exc()
                bot.sendMessage(
                    chat_id, 'Impossibile collegarsi a telecamera ' + command)
        elif noermalizedCommand in commandList:
            print("Ricevuto come Azione")
            cmd = commandList[noermalizedCommand]
            res = os.popen(cmd).read()
            message = os.popen(
                "sudo service zoneminder status | head -3 | tail -1 | cut -f2 -d'(' | cut -f1 -d')'").read()
            bot.sendMessage(chat_id, message)

        elif sender in adminChatIds and len(command) > 1 and command != "sudo su" and "nano" not in command:
            try:
                message = os.popen(command).read()
                bot.sendMessage(chat_id, message)
            except:
                bot.sendMessage(chat_id, "comando non valido")
        else:
            print("Messaggio sbagliato")
            bot.sendMessage(chat_id, "Comando non recepito")
    else:
        bot.sendMessage(
            chat_id, 'Non sei autorizzate a darmi ordini! Il tuo codice chat è: ' + sender)


print("Bot Token: " + botToken)
bot = telepot.Bot(botToken)
bot.message_loop(handle)

print('I am listening ...')

while 1:
    time.sleep(10000)
