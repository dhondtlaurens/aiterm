import Foundation

public enum SignalTransitionError: Error, Equatable { case invalidEdge, workerIsWorking }
