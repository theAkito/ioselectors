import lists, options
import math


const
  widthBits {.intdefine.} = 4
  total {.intdefine.} = 16
  totalBits* = 1 shl total
  # numLevels = (32 + widthBits - 1) div widthBits
  numLevels* = total div widthBits
  numSlots = 1 shl widthBits
  mask* = numSlots - 1

static:
  doAssert isPowerOfTwo(widthBits)
  doAssert isPowerOfTwo(total)

type
  Tick* = Natural

  Callback* = proc() {.gcsafe.}

  TimerEvent* = object
    finishAt*: Tick
    timeout*: Tick
    repeatTimes*: int
    cb*: Callback
    count*: Tick

  TimerEventNode* = DoublyLinkedNode[TimerEvent]

  TimerEventList* = ref object
    data*: DoublyLinkedList[TimerEvent]
    count*: Tick

  TimerWheel* = object
    taskCounter*: Natural
    duration*: array[numLevels, Tick]
    currentTime*: Tick
    now*: array[numLevels, Tick]
    slots*: array[numLevels, array[numSlots, TimerEventList]]


proc initTimerWheel*(): TimerWheel =
  for level in 0 ..< numLevels:
    result.duration[level] = numSlots ^ (level + 1)

    for idx in 0 ..< numSlots:
      new result.slots[level][idx]

proc isActive*(s: TimerWheel): bool =
  s.taskCounter != 0

proc initTimerEvent*(cb: Callback): TimerEvent =
  TimerEvent(cb: cb)

proc `$`*(t: TimerEvent): string =
  $(t.finishAt, )

proc slotsToString*(t: TimerWheel, level: Tick): string =
  result = "["
  let slots = t.slots[level]
  for idx in 0 ..< numSlots - 1:
    result.add $(slots[idx][]) & ", "
  result.add $(slots[^1][])
  result.add "]"

proc isEmpty*(L: TimerEventList): bool =
  L.data.head == nil and L.data.tail == nil

proc clear*(L: TimerEventList) =
  L.data.head = nil
  L.data.tail = nil
  L.count = 0

proc append*(L: TimerEventList, ev: TimerEventNode) =
  L.data.append(ev)
  inc L.count


proc internalRemove*[T](L: var DoublyLinkedList[T], n: DoublyLinkedNode[T]): bool =
  result = false

  if n == L.tail: 
    L.tail = n.prev
    result = true

  if n == L.head: 
    L.head = n.next
    result = true

  if n.next != nil: 
    n.next.prev = n.prev
    result = true

  if n.prev != nil: 
    n.prev.next = n.next
    result = true

proc remove*(L: TimerEventList, ev: TimerEventNode): bool =
  result = L.data.internalRemove(ev)
  if result:
    dec L.count

iterator mitems*(L: TimerEventList): var TimerEvent =
  for item in L.data.mitems:
    yield item

iterator items*(L: TimerEventList): TimerEvent =
  for item in L.data.items:
    yield item

iterator nodes*(L: TimerEventList): TimerEventNode =
  for item in L.data.nodes:
    yield item

proc setTimer*(s: var TimerWheel, event: TimerEventNode, 
               timeout: Tick) =
  ## Returns the number of TimerEvent in TimerEventList.
  if event.value.repeatTimes == 0:
    return

  # mod (2 ^ n - 1)
  var level = 0
  # decide which level
  while timeout >= s.duration[level]:
    inc level

    if level >= numLevels:
      doAssert false, "Number is too large "

  event.value.timeout = timeout
  event.value.finishAt = s.currentTime + timeout

  let scheduleAt = 
    if level == 0:
      event.value.finishAt and mask
    else:
      (s.now[level] + (timeout div s.duration[level - 1]) - 1) and mask


  event.value.count = s.slots[level][scheduleAt].count

  s.slots[level][scheduleAt].append event
  inc s.taskCounter

proc setTimer*(s: var TimerWheel, event: var TimerEvent, 
               timeout: Tick, repeatTimes: int = 1): TimerEventNode =
  ## Returns the number of TimerEvent in TimerEventList.
  event.repeatTimes = repeatTimes
  result = newDoublyLinkedNode(event)
  s.setTimer(result, timeout)

proc cancel*(s: var TimerWheel, eventNode: TimerEventNode) =
  # mod (2 ^ n - 1)
  var level = 0

  let event = eventNode.value
  # decide which level
  while event.timeout >= s.duration[level]:
    inc level

    if level >= numLevels:
      doAssert false, "Number is too large "

  let scheduleAt = 
    if level == 0:
      event.finishAt and mask
    else:
      (s.now[level] + (event.timeout div s.duration[level - 1]) - 1) and mask


  if s.slots[level][scheduleAt].remove(eventNode):
    dec s.taskCounter

proc execute*(s: var TimerWheel, t: TimerEventNode) =
  if t.value.cb != nil:
    t.value.cb()

    if t.value.repeatTimes < 0:
      setTimer(s, t, t.value.timeout)
    elif t.value.repeatTimes >= 1:
      dec t.value.repeatTimes
      setTimer(s, t, t.value.timeout)

proc degrade*(s: var TimerWheel, hlevel: Tick) =
  let idx = s.now[hlevel] - 1

  if idx >= 0:
    for node in s.slots[hlevel][idx].nodes:
      discard s.slots[hlevel][idx].remove(node)
      if node.value.finishAt <= s.currentTime:
        s.execute(node)
      else:
        s.setTimer(node, node.value.finishAt - s.currentTime)
      dec s.taskCounter

proc advance*(s: var TimerWheel, step: Tick) =
  for i in 0 ..< step:
    let idx = s.now[0]
    for node in s.slots[0][idx].nodes:
      s.execute(node)
      dec s.taskCounter

    s.slots[0][idx].clear()

    s.now[0] = (idx + 1) and mask

    var hlevel = 0

    while s.now[hlevel] == 0 and hlevel < numLevels - 1:
      inc hlevel
      s.now[hlevel] = (s.now[hlevel] + 1) and mask
      degrade(s, hlevel)

    s.currentTime = (s.currentTime + 1) and (totalBits - 1)

proc update*(s: var TimerWheel, step: Tick) =
  for i in 0 ..< step:
    let idx = s.now[0]

    s.now[0] = (idx + 1) and mask

    var hlevel = 0

    while s.now[hlevel] == 0 and hlevel < numLevels - 1:
      inc hlevel
      s.now[hlevel] = (s.now[hlevel] + 1) and mask
      degrade(s, hlevel)

    s.currentTime = (s.currentTime + 1) and (totalBits - 1)


  let idx = s.now[0]
  for node in s.slots[0][idx].nodes:
    s.execute(node)
    dec s.taskCounter

  s.slots[0][idx].clear()
