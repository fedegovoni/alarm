import RPi.GPIO as GPIO
import subprocess

GPIO.setmode(GPIO.BCM)

MATRIX = [  [1,2,3],
	    [4,5,6],
	    [7,8,9],
	    ['*',0,'#'] ]

ROW = [18,23,24,25]
COL = [4,17,22]

code = ""

for j in range(3):
 GPIO.setup(COL[j], GPIO.OUT)
 GPIO.output(COL[j], 1)

for i in range(4):
 GPIO.setup(ROW[i], GPIO.IN, pull_up_down = GPIO.PUD_UP)

try:
 while(True):
  for j in range(3):
   GPIO.output(COL[j], 0)

   for i in range(4):
    if GPIO.input(ROW[i]) == 0:
     if MATRIX[i][j] == '*':
      code = ""
     elif MATRIX[i][j] == '#':
      bashCommand = "ssh fede@192.168.0.10 \"/home/fede/allarme/checkCode \"" + code
      print subprocess.Popen(bashCommand, shell=True, stdout=subprocess.PIPE).stdout.read()
      code = ""
     else:
      code = code + str(MATRIX[i][j])
      print(code)
     while(GPIO.input(ROW[i]) == 0):
      pass
   GPIO.output(COL[j],1)

except KeyboardInterrupt:
 GPIO.cleanup()

