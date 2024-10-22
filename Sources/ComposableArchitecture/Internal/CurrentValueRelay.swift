import Combine
import CombineSchedulers
import Foundation

final class CurrentValueRelay<Output>: Publisher {
  typealias Failure = Never

  private var currentValue: Output
  private let lock: os_unfair_lock_t
  private var subscriptions = ContiguousArray<Subscription>()

  var value: Output {
    get { self.lock.sync { self.currentValue } }
    set { self.send(newValue) }
  }

  init(_ value: Output) {
    self.currentValue = value
    self.lock = os_unfair_lock_t.allocate(capacity: 1)
    self.lock.initialize(to: os_unfair_lock())
  }

  deinit {
    self.lock.deinitialize(count: 1)
    self.lock.deallocate()
  }

  func receive(subscriber: some Subscriber<Output, Never>) {
    let subscription = Subscription(upstream: self, downstream: subscriber)
    self.lock.sync {
      self.subscriptions.append(subscription)
    }
    subscriber.receive(subscription: subscription)
  }

  func send(_ value: Output) {
    self.lock.sync {
      self.currentValue = value
    }
    for subscription in self.lock.sync({ self.subscriptions }) {
      subscription.receive(value)
    }
  }

  private func remove(_ subscription: Subscription) {
    self.lock.sync {
      guard let index = self.subscriptions.firstIndex(of: subscription)
      else { return }
      self.subscriptions.remove(at: index)
    }
  }
}

extension CurrentValueRelay {
  fileprivate final class Subscription: Combine.Subscription, Equatable {
    private var demand = Subscribers.Demand.none
    private var downstream: (any Subscriber<Output, Never>)?
    private let lock: os_unfair_lock_t
    private var receivedLastValue = false
    private var upstream: CurrentValueRelay?

    init(upstream: CurrentValueRelay, downstream: any Subscriber<Output, Never>) {
      self.upstream = upstream
      self.downstream = downstream
      self.lock = os_unfair_lock_t.allocate(capacity: 1)
      self.lock.initialize(to: os_unfair_lock())
    }

    deinit {
      self.lock.deinitialize(count: 1)
      self.lock.deallocate()
    }

    func cancel() {
      self.lock.sync {
        self.downstream = nil
        self.upstream?.remove(self)
        self.upstream = nil
      }
    }

    func receive(_ value: Output) {
      os_unfair_lock_lock(self.lock)

      guard let downstream else {
        os_unfair_lock_unlock(self.lock)
        return
      }

      switch self.demand {
      case .unlimited:
        os_unfair_lock_unlock(self.lock)
        // NB: Adding to unlimited demand has no effect and can be ignored.
        _ = downstream.receive(value)

      case .none:
        self.receivedLastValue = false
        os_unfair_lock_unlock(self.lock)

      default:
        self.receivedLastValue = true
        self.demand -= 1
        os_unfair_lock_unlock(self.lock)
        let moreDemand = downstream.receive(value)
        self.lock.sync {
          self.demand += moreDemand
        }
      }
    }

    func request(_ demand: Subscribers.Demand) {
      precondition(demand > 0, "Demand must be greater than zero")

      os_unfair_lock_lock(self.lock)

      guard let downstream else {
        os_unfair_lock_unlock(self.lock)
        return
      }

      self.demand += demand

      guard
        !self.receivedLastValue,
        let value = self.upstream?.value
      else {
        os_unfair_lock_unlock(self.lock)
        return
      }

      self.receivedLastValue = true

      switch self.demand {
      case .unlimited:
        os_unfair_lock_unlock(self.lock)
        // NB: Adding to unlimited demand has no effect and can be ignored.
        _ = downstream.receive(value)

      default:
        self.demand -= 1
        os_unfair_lock_unlock(self.lock)
        let moreDemand = downstream.receive(value)
        os_unfair_lock_lock(self.lock)
        self.demand += moreDemand
        os_unfair_lock_unlock(self.lock)
      }
    }

    static func == (lhs: Subscription, rhs: Subscription) -> Bool {
      lhs === rhs
    }
  }
}
