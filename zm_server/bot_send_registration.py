import sys
import os
import telepot
import time
import datetime
import urllib3
import io
import mysql.connector as mysql
import subprocess
import configparser

import numpy as np
import argparse
import time
import cv2
import numpy as np
import matplotlib.pyplot as plt
import glob


def analyzeVideo(inputPath, outputPath):
    # initialize the HOG descriptor/person detector
    hog = cv2.HOGDescriptor()
    hog.setSVMDetector(cv2.HOGDescriptor_getDefaultPeopleDetector())
    img_array = []

    # cv2.startWindowThread()
    print("Analyze video")
    size = (0, 0)

    for filename in glob.glob(inputPath + "/*.jpg"):
        img = cv2.imread(filename)
        height, width, layers = img.shape
        size = (width, height)

        print("Iterate on file " + filename)

        # using a greyscale picture, also for faster detection
        gray = cv2.cvtColor(img, cv2.COLOR_RGB2GRAY)

        # detect people in the image
        # returns the bounding boxes for the detected objects
        boxes, weights = hog.detectMultiScale(img, winStride=(8, 8))

        boxes = np.array([[x, y, x + w, y + h] for (x, y, w, h) in boxes])

        for (xA, yA, xB, yB) in boxes:
            # display the detected boxes in the colour picture
            cv2.rectangle(img, (xA, yA), (xB, yB),
                          (0, 255, 0), 2)

        img_array.append(img)

    print("Fuori dal loop")
    #out = cv2.VideoWriter('opencv_event.avi',cv2.VideoWriter_fourcc(*'DIVX'), 15, size)
    #out = cv2.VideoWriter('opencv_event.avi', -1, 20, (640, 480))
    out = cv2.VideoWriter('opencv_event.avi',
                          cv2.VideoWriter_fourcc(*'MJPG'), 20, (640, 480))

    for outImg in img_array:
        out.write(outImg)

    # and release the output
    out.release()


configParser = configparser.RawConfigParser()
configFilePath = r'./cameras.conf'
configParser.read(configFilePath)

authorizedChatIds = configParser['TELEGRAM_AUTHORIZED_CHAT_IDS']['IDS'].split(
    ',')
botToken = configParser['TELEGRAM_BOT_TOKEN']['AUTH_TOKEN']
createVideoScriptPath = configParser['PATH_PARAMS']['CREATE_VIDEO_SCRIPT_PATH']
eventVideoBasePath = configParser['PATH_PARAMS']['EVENT_VIDEO_BASE_PATH']

dbUser = configParser['DATABASE_PARAMS']['USERNAME']
dbPassword = configParser['DATABASE_PARAMS']['PASSWORD']
dbHost = configParser['DATABASE_PARAMS']['DB_HOST']
dbName = configParser['DATABASE_PARAMS']['DB_NAME']

standardCascade = cv2.CascadeClassifier()

bot = telepot.Bot(botToken)

for chat_id in authorizedChatIds:
    print("Send message to chat id: " + chat_id)
    bot.sendMessage(chat_id, "Allarme campagna!")

# Invio delle immagini registrate
sqlQuery = "select e.MonitorId, e.StartTime, e.Width, e.Height, m.Name, e.Id from Events as e left join Monitors m on m.Id = e.MonitorId order by e.id desc limit 1"
db = mysql.connect(
    host=dbHost,
    username=dbUser,
    password=dbPassword,
    database=dbName
)

cursor = db.cursor()
try:
    cursor.execute(sqlQuery)
    row = cursor.fetchall()[0]
    monitorId = row[0]
    starttime = row[1]
    videoWidth = row[2]
    videoHeight = row[3]
    monitorName = row[4]
    eventId = row[5]
except:
    print("Error: unable to fetch data")
db.close()

path = eventVideoBasePath + str(monitorId) + "/"
date = starttime.strftime('%Y-%m-%d')
path = path + date + "/" + str(eventId)
videoFilePath = path + "/video.mp4"
os.chdir(path)

if not os.path.exists('video.mp4'):
    bot.sendMessage(chat_id, "Allarme campagna %s" % monitorName)
    bashCommand = "sudo " + createVideoScriptPath + " ./"
    process = subprocess.Popen(bashCommand.split(), stdout=subprocess.PIPE)
    output, error = process.communicate()

    # print("pre-analyzevideo")
    #analyzeVideo(videoFilePath, path)
    # print("post-analyzevideo")

    try:
        bot.sendVideo(chat_id, open("video.mp4"))
    except:
        bot.sendMessage(
            chat_id, 'Impossibile inviare immagine della registrazione')
