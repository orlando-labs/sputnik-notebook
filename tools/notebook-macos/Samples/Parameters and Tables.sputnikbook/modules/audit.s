package audit
class Counter:
  def init(): @value = 0
  def next():
    @value += 1
    @value
State = Counter()
def tick(): State.next()
export tick
