import Foundation

struct MonitorIssue: Identifiable, Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case ports
        case launchAgents
    }

    var id: Source { source }
    let source: Source
    let message: String
}

struct MonitorSnapshot: Equatable, Sendable {
    let services: [MonitoredService]
    let issues: [MonitorIssue]
    let collectedAt: Date
    let collectionDuration: TimeInterval

    static let empty = MonitorSnapshot(
        services: [],
        issues: [],
        collectedAt: .distantPast,
        collectionDuration: 0
    )
}

protocol ServiceDiscovering: Sendable {
    func discover() async -> MonitorSnapshot
}

struct ServiceGrouper: Sendable {
    private let projectResolver: any ProjectResolving

    init(projectResolver: any ProjectResolving) {
        self.projectResolver = projectResolver
    }

    func group(
        portRecords: [PortRecord],
        processes: [Int32: MonitoredProcess],
        launchAgents: [LaunchAgentInfo]
    ) -> [MonitoredService] {
        let agentsByPID = Dictionary(uniqueKeysWithValues: launchAgents.map { ($0.pid, $0) })
        let portsByPID = Dictionary(grouping: portRecords, by: \.pid)
        var groups: [GroupKey: ServiceAccumulator] = [:]

        for process in processes.values.sorted(by: { $0.id.pid < $1.id.pid }) {
            let records = portsByPID[process.id.pid] ?? []
            let descriptor = descriptor(
                for: process,
                launchAgent: agentsByPID[process.id.pid],
                portRecords: records
            )

            var accumulator = groups[descriptor.key] ?? ServiceAccumulator(descriptor: descriptor)
            accumulator.processes.append(process)
            accumulator.endpoints.formUnion(records.map(\.endpoint))
            groups[descriptor.key] = accumulator
        }

        return groups.values.map { $0.service }
            .sorted(by: serviceSort)
    }

    private func descriptor(
        for process: MonitoredProcess,
        launchAgent: LaunchAgentInfo?,
        portRecords: [PortRecord]
    ) -> ServiceDescriptor {
        if let launchAgent {
            return ServiceDescriptor(
                key: .launchAgent(launchAgent.label),
                displayName: launchAgent.label,
                kind: .launchAgent,
                projectRoot: nil,
                launchAgentLabel: launchAgent.label
            )
        }

        if
            let workingDirectory = process.workingDirectory,
            let project = projectResolver.resolve(workingDirectory: workingDirectory)
        {
            return ServiceDescriptor(
                key: .project(project.rootURL.path),
                displayName: project.name,
                kind: .localProject,
                projectRoot: project.rootURL,
                launchAgentLabel: nil
            )
        }

        let command = portRecords.compactMap(\.command).first
        let executableName = URL(fileURLWithPath: process.executablePath).lastPathComponent
        return ServiceDescriptor(
            key: .process(process.id),
            displayName: command ?? (executableName.isEmpty ? "PID \(process.id.pid)" : executableName),
            kind: .userProcess,
            projectRoot: nil,
            launchAgentLabel: nil
        )
    }

    private func serviceSort(_ lhs: MonitoredService, _ rhs: MonitoredService) -> Bool {
        let leftRank = rank(lhs.kind)
        let rightRank = rank(rhs.kind)
        if leftRank != rightRank { return leftRank < rightRank }

        let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
    }

    private func rank(_ kind: MonitoredService.Kind) -> Int {
        switch kind {
        case .localProject: 0
        case .launchAgent: 1
        case .userProcess: 2
        }
    }
}

struct DiscoveryEngine: ServiceDiscovering {
    private let portCollector: any PortCollecting
    private let processCollector: any ProcessCollecting
    private let launchAgentCollector: any LaunchAgentCollecting
    private let serviceGrouper: ServiceGrouper

    init(
        portCollector: any PortCollecting,
        processCollector: any ProcessCollecting,
        launchAgentCollector: any LaunchAgentCollecting,
        serviceGrouper: ServiceGrouper
    ) {
        self.portCollector = portCollector
        self.processCollector = processCollector
        self.launchAgentCollector = launchAgentCollector
        self.serviceGrouper = serviceGrouper
    }

    func discover() async -> MonitorSnapshot {
        let startedAt = Date()
        async let portResult = collectPorts()
        async let launchAgentResult = collectLaunchAgents()
        let (ports, launchAgents) = await (portResult, launchAgentResult)

        let candidatePIDs = Set(ports.values.map(\.pid) + launchAgents.values.map(\.pid))
        let processes = candidatePIDs.reduce(into: [Int32: MonitoredProcess]()) { result, pid in
            result[pid] = processCollector.collect(pid: pid)
        }

        return MonitorSnapshot(
            services: serviceGrouper.group(
                portRecords: ports.values,
                processes: processes,
                launchAgents: launchAgents.values
            ),
            issues: [ports.issue, launchAgents.issue].compactMap { $0 },
            collectedAt: Date(),
            collectionDuration: Date().timeIntervalSince(startedAt)
        )
    }

    private func collectPorts() async -> PortCollectionResult {
        do {
            return PortCollectionResult(values: try await portCollector.collect(), issue: nil)
        } catch {
            return PortCollectionResult(
                values: [],
                issue: MonitorIssue(source: .ports, message: String(describing: error))
            )
        }
    }

    private func collectLaunchAgents() async -> LaunchAgentCollectionResult {
        do {
            return LaunchAgentCollectionResult(
                values: try await launchAgentCollector.collect(),
                issue: nil
            )
        } catch {
            return LaunchAgentCollectionResult(
                values: [],
                issue: MonitorIssue(source: .launchAgents, message: String(describing: error))
            )
        }
    }
}

private enum GroupKey: Hashable {
    case project(String)
    case launchAgent(String)
    case process(ProcessIdentity)

    var id: String {
        switch self {
        case .project(let path): "project:\(path)"
        case .launchAgent(let label): "launch:\(label)"
        case .process(let identity):
            "process:\(identity.pid):\(identity.startTime.timeIntervalSince1970)"
        }
    }
}

private struct ServiceDescriptor {
    let key: GroupKey
    let displayName: String
    let kind: MonitoredService.Kind
    let projectRoot: URL?
    let launchAgentLabel: String?
}

private struct ServiceAccumulator {
    let descriptor: ServiceDescriptor
    var processes: [MonitoredProcess] = []
    var endpoints: Set<ListeningEndpoint> = []

    var service: MonitoredService {
        MonitoredService(
            id: descriptor.key.id,
            displayName: descriptor.displayName,
            kind: descriptor.kind,
            projectRoot: descriptor.projectRoot,
            launchAgentLabel: descriptor.launchAgentLabel,
            processes: processes.sorted { $0.id.pid < $1.id.pid },
            endpoints: endpoints.sorted {
                if $0.port != $1.port { return $0.port < $1.port }
                if $0.transport != $1.transport {
                    return $0.transport.rawValue < $1.transport.rawValue
                }
                return $0.address < $1.address
            }
        )
    }
}

private struct PortCollectionResult: Sendable {
    let values: [PortRecord]
    let issue: MonitorIssue?
}

private struct LaunchAgentCollectionResult: Sendable {
    let values: [LaunchAgentInfo]
    let issue: MonitorIssue?
}

