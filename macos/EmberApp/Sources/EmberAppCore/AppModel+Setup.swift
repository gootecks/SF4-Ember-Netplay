import Foundation

extension AppModel {
    public func refreshSetup() async {
        var allDone = true
        for step in SetupStep.allCases {
            if setupRunning, steps[step] == .running { allDone = false; continue }
            let done = await backend.isDone(step)
            if done {
                steps[step] = .done
            } else {
                allDone = false
                if steps[step] == .done || steps[step] == .running { steps[step] = .pending }
            }
        }
        if allDone {
            phase = .ready
            await refreshStatus()
        } else {
            phase = .setup
        }
    }

    public func runSetup() {
        guard setupTask == nil else { return }
        setupRunning = true
        setupTask = Task { [weak self] in
            await self?.setupLoop()
            self?.setupTask = nil
            self?.setupRunning = false
        }
    }

    public func cancelSetup() {
        setupTask?.cancel()
    }

    public func chooseGame(_ choice: GameChoice) {
        gameChoice = choice
        steps[.game] = .pending
        runSetup()
    }

    public func installRosetta() {
        guard setupTask == nil else { return }
        setupRunning = true
        steps[.rosetta] = .running
        progress = "Waiting for administrator approval to install Rosetta 2"
        setupTask = Task { [weak self] in
            guard let self else { return }
            do {
                self.record("installing Rosetta 2")
                try await self.rosettaInstaller()
                self.setupTask = nil
                self.setupRunning = false
                self.runSetup()
            } catch {
                self.steps[.rosetta] = .failed(error.localizedDescription)
                self.record("Rosetta install failed: \(error.localizedDescription)")
                self.setupTask = nil
                self.setupRunning = false
            }
        }
    }

    func setupLoop() async {
        let log = sink()
        for step in SetupStep.allCases {
            if Task.isCancelled { return }
            if await backend.isDone(step) {
                steps[step] = .done
                continue
            }
            if step == .game, gameChoice == nil {
                steps[step] = .needsInput
                return
            }
            steps[step] = .running
            progress = ""
            record("setup step \(step.rawValue): start")
            do {
                try await backend.perform(step, game: gameChoice, policy: settings.policy, log: log)
                steps[step] = .done
                record("setup step \(step.rawValue): done")
            } catch is CancellationError {
                steps[step] = .pending
                record("setup step \(step.rawValue): cancelled")
                return
            } catch {
                if step == .game { gameChoice = nil }
                steps[step] = .failed(error.localizedDescription)
                record("setup step \(step.rawValue): failed: \(error.localizedDescription)")
                return
            }
        }
        startedSteam = false
        progress = ""
        phase = .ready
        record("setup complete")
        await refreshStatus()
        await refreshLatest()
    }
}
