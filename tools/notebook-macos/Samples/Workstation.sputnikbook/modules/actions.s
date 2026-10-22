package actions
import task
class Counter:
  def init(): @value = 0
  def next():
    @value += 1
    @value
State = Counter()
def calibrate(gain, offset, label):
  print(label)
  [gain * 10 + offset, State.next()]
def slow():
  task.sleep(60000)
  1
export calibrate, slow
