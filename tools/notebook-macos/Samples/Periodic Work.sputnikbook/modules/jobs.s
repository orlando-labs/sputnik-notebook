package jobs

# Every Periodic Work component owns a persistent module runtime.
class Counter:
  def init(): @value = 0
  def next():
    @value += 1
    @value

State = Counter()

def tick(): State.next()

def fail(): raise "Example periodic failure"

export tick, fail
