import Foundation

extension EditorViewModel {
    func addGuide(axis: GuideAxis, position: Double) {
        let clamped = max(0, min(1, position))
        let guide = Guide(axis: axis, position: clamped)
        timeline.guides.append(guide)
        undoManager?.registerUndo(withTarget: self) { vm in vm.removeGuide(id: guide.id) }
        undoManager?.setActionName("Add Guide")
        notifyTimelineChanged()
    }

    func moveGuide(id: String, to position: Double) {
        guard let i = timeline.guides.firstIndex(where: { $0.id == id }) else { return }
        let prev = timeline.guides[i].position
        timeline.guides[i].position = max(0, min(1, position))
        undoManager?.registerUndo(withTarget: self) { vm in vm.moveGuide(id: id, to: prev) }
        undoManager?.setActionName("Move Guide")
        notifyTimelineChanged()
    }

    func removeGuide(id: String) {
        guard let i = timeline.guides.firstIndex(where: { $0.id == id }) else { return }
        let removed = timeline.guides[i]
        timeline.guides.remove(at: i)
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.timeline.guides.insert(removed, at: min(i, vm.timeline.guides.count))
            vm.notifyTimelineChanged()
        }
        undoManager?.setActionName("Delete Guide")
        notifyTimelineChanged()
    }

    func clearGuides() {
        guard !timeline.guides.isEmpty else { return }
        let saved = timeline.guides
        timeline.guides = []
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.timeline.guides = saved
            vm.notifyTimelineChanged()
        }
        undoManager?.setActionName("Clear Guides")
        notifyTimelineChanged()
    }
}
