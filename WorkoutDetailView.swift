import SwiftData
import SwiftUI

private enum WorkoutTemplateSheet: Identifiable {
    case addExercise
    case configureExercise(WorkoutExercise)
    case replaceExercise(WorkoutExercise)

    var id: String {
        switch self {
        case .addExercise:
            "addExercise"
        case .configureExercise(let exercise):
            "configure-\(exercise.id)"
        case .replaceExercise(let exercise):
            "replace-\(exercise.id)"
        }
    }
}

struct WorkoutDetailView: View {
    @Environment(\.editMode) private var editMode
    @Environment(\.modelContext) private var modelContext
    @Environment(ActiveWorkoutSessionManager.self) private var activeSessionManager
    @Query private var preferences: [UserPreferences]
    @Bindable var workout: Workout

    @State private var presentedSheet: WorkoutTemplateSheet?

    // Draft state so Cancel can revert changes instead of behaving like Save.
    @State private var originalWorkoutName: String = ""
    @State private var draftWorkoutName: String = ""

    private var preference: UserPreferences? {
        preferences.first
    }

    private var unitSystem: UnitSystem {
        preference?.unitSystem ?? .metric
    }

    private var isEditing: Bool {
        editMode?.wrappedValue.isEditing == true
    }

    private var isWorkoutNameValid: Bool {
        let name = isEditing ? draftWorkoutName : workout.name
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            TemplateHeaderSection(
                workout: workout,
                isEditing: isEditing,
                draftWorkoutName: $draftWorkoutName
            )

            Section("Exercises") {
                if workout.exercises.isEmpty {
                    Text("Add exercises from the library, then configure sets, rest, tracking, and notes here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(workout.orderedExercises) { exercise in
                        WorkoutTemplateExerciseRow(
                            exercise: exercise,
                            unitSystem: unitSystem,
                            isEditing: isEditing,
                            onConfigure: { presentedSheet = .configureExercise(exercise) },
                            onReplace: { presentedSheet = .replaceExercise(exercise) },
                            onDelete: { deleteExercise(exercise) }
                        )
                    }
                    .onMove { source, destination in
                        WorkoutPersistenceService.moveExercises(in: workout, from: source, to: destination)
                    }
                    .onDelete { offsets in
                        let ordered = workout.orderedExercises
                        offsets.map { ordered[$0] }.forEach(deleteExercise)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isEditing)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isEditing {
                    Button("Cancel") {
                        cancelEditing()
                    }
                } else {
                    Button("Edit") {
                        beginEditing()
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                if isEditing {
                    Button(action: saveEditing) {
                        Text("Save")
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.regular)
                    .buttonBorderShape(.automatic)
                    .tint(.blue)
                    .disabled(!isWorkoutNameValid)
                } else if !workout.exercises.isEmpty {
                    Button(action: startWorkout) {
                        Text("Start")
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.regular)
                    .buttonBorderShape(.automatic)
                    .tint(.green)
                }
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .addExercise:
                ExercisePickerView { exercise, selectedEquipment, selectedTracking in
                    let defaultWeight = selectedTracking == .setsRepsWeight
                        ? Formatters.defaultWeight(for: unitSystem)
                        : nil
                    WorkoutPersistenceService.addExercise(
                        exercise,
                        to: workout,
                        selectedEquipment: selectedEquipment,
                        selectedTracking: selectedTracking,
                        defaultWeight: defaultWeight
                    )
                }
            case .configureExercise(let exercise):
                ExerciseConfigurationSheet(exercise: exercise)
            case .replaceExercise(let exercise):
                ExercisePickerView(allowsMultipleSelection: false) { replacement, selectedEquipment, selectedTracking in
                    let defaultWeight = selectedTracking == .setsRepsWeight
                        ? Formatters.defaultWeight(for: unitSystem)
                        : nil
                    WorkoutPersistenceService.replaceExercise(
                        exercise,
                        with: replacement,
                        selectedEquipment: selectedEquipment,
                        selectedTracking: selectedTracking,
                        defaultWeight: defaultWeight,
                        modelContext: modelContext
                    )
                }
            }
        }
        .alert(
            "A workout is already active",
            isPresented: activeConflictBinding,
            actions: {
                Button("Resume Current Workout") {
                    activeSessionManager.resume()
                    activeSessionManager.activeConflictWorkout = nil
                }

                Button("Finish Current Workout") {
                    finishCurrentAndStartRequestedWorkout()
                }

                Button("Discard Current Workout", role: .destructive) {
                    discardCurrentAndStartRequestedWorkout()
                }

                Button("Cancel", role: .cancel) {
                    activeSessionManager.activeConflictWorkout = nil
                }
            },
            message: {
                Text("Only one workout can be active at a time.")
            }
        )
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button {
                    presentedSheet = .addExercise
                } label: {
                    Label("Add Exercises", systemImage: "plus")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .adaptiveGlassPill()
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.bottom, 8)
        }
        .onAppear {
            // Keep draft in sync for the first render.
            if draftWorkoutName.isEmpty {
                draftWorkoutName = workout.name
            }
        }
    }

    private var activeConflictBinding: Binding<Bool> {
        Binding {
            activeSessionManager.activeConflictWorkout != nil
        } set: { isPresented in
            if !isPresented {
                activeSessionManager.activeConflictWorkout = nil
            }
        }
    }

    private func beginEditing() {
        originalWorkoutName = workout.name
        draftWorkoutName = workout.name

        withAnimation {
            editMode?.wrappedValue = .active
        }
    }

    private func cancelEditing() {
        // Revert changes made during editing.
        workout.name = originalWorkoutName
        draftWorkoutName = originalWorkoutName

        withAnimation {
            editMode?.wrappedValue = .inactive
        }
    }

    private func saveEditing() {
        let trimmedName = draftWorkoutName.trimmingCharacters(in: .whitespacesAndNewlines)
        workout.name = trimmedName
        workout.updatedAt = .now

        withAnimation {
            editMode?.wrappedValue = .inactive
        }
    }

    private func startWorkout() {
        activeSessionManager.requestStart(
            workout: workout,
            preferences: preference,
            modelContext: modelContext
        )
    }

    private func deleteExercise(_ exercise: WorkoutExercise) {
        modelContext.delete(exercise)
        workout.updatedAt = .now
    }

    private func finishCurrentAndStartRequestedWorkout() {
        guard let requestedWorkout = activeSessionManager.activeConflictWorkout else { return }
        activeSessionManager.saveCurrentSession()
        activeSessionManager.start(workout: requestedWorkout, preferences: preference, modelContext: modelContext)
        activeSessionManager.activeConflictWorkout = nil
    }

    private func discardCurrentAndStartRequestedWorkout() {
        guard let requestedWorkout = activeSessionManager.activeConflictWorkout else { return }
        activeSessionManager.discardCurrentSession(in: modelContext)
        activeSessionManager.start(workout: requestedWorkout, preferences: preference, modelContext: modelContext)
        activeSessionManager.activeConflictWorkout = nil
    }
}

private struct TemplateHeaderSection: View {
    @Bindable var workout: Workout
    let isEditing: Bool
    @Binding var draftWorkoutName: String

    var body: some View {
        Section {
            GlassSurface() {
                VStack(alignment: .leading, spacing: 12) {
                    if isEditing {
                        TextField("Workout name", text: $draftWorkoutName)
                            .font(.title2.weight(.semibold))
                            .textInputAutocapitalization(.words)

                        EditableTagChips(workout: workout)
                    } else {
                        Text(workout.name)
                            .font(.title2.weight(.semibold))

                        ReadOnlyTagChips(tags: workout.tags)
                    }
                }
            }
            .listRowBackground(Color.clear)
        }
    }
}

private struct WorkoutTemplateExerciseRow: View {
    @Bindable var exercise: WorkoutExercise
    let unitSystem: UnitSystem
    let isEditing: Bool
    let onConfigure: () -> Void
    let onReplace: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(exercise.exerciseName)
                    .font(.headline)

                Text("\(exercise.selectedEquipment) · \(exercise.trackingType.shortLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if !isEditing {
                Menu {
                    Button("Edit", systemImage: "slider.horizontal.3", action: onConfigure)
                    Button("Replace", systemImage: "arrow.triangle.2.circlepath", action: onReplace)
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Exercise options")
                .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
        .animation(.snappy, value: isEditing)
    }

    private var summaryText: String {
        let setCount = max(exercise.setTemplates.count, 1)
        let setsLabel = setCount == 1 ? "1 Set" : "\(setCount) Sets"

        switch exercise.trackingType {
        case .setsRepsWeight:
            let repsValues = exercise.setTemplates.map(\.targetReps)
            let weightValues = exercise.setTemplates.compactMap { $0.targetWeight }
            let reps = rangeLabel(repsValues, unit: "reps")
            let weight = weightRangeLabel(weightValues, unit: unitSystem.weightUnit)
            if let weight {
                return "\(setsLabel) • \(reps) • \(weight)"
            }
            return "\(setsLabel) • \(reps)"
        case .repsOnly:
            let repsValues = exercise.setTemplates.map(\.targetReps)
            return "\(setsLabel) • \(rangeLabel(repsValues, unit: "reps"))"
        case .durationIntervals:
            let durationValues = exercise.setTemplates.map(\.targetDurationSeconds)
            return "\(setsLabel) • \(rangeLabel(durationValues, unit: "sec"))"
        case .simpleCheckOff:
            return "\(setsLabel) • Check Off"
        }
    }

    private func rangeLabel<T: Comparable>(_ values: [T], unit: String) -> String where T: LosslessStringConvertible {
        guard let minValue = values.min(), let maxValue = values.max() else {
            return "-- \(unit)"
        }

        if minValue == maxValue {
            return "\(minValue) \(unit)"
        }

        return "\(minValue)–\(maxValue) \(unit)"
    }

    private func weightRangeLabel(_ values: [Double], unit: String) -> String? {
        guard let minValue = values.min(), let maxValue = values.max() else { return nil }
        if minValue == maxValue {
            return "\(Formatters.weightNumber(minValue)) \(unit)"
        }
        return "\(Formatters.weightNumber(minValue))–\(Formatters.weightNumber(maxValue)) \(unit)"
    }
}

private extension View {
    @ViewBuilder
    func adaptiveGlassPill() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self.background(.thinMaterial, in: Capsule())
        }
    }
}

#Preview {
    NavigationStack {
        WorkoutDetailView(workout: PreviewContainer.container.mainContext.fetchPreviewWorkout())
    }
    .modelContainer(PreviewContainer.container)
    .environment(ExerciseLibraryService.preview)
    .environment(ActiveWorkoutSessionManager())
}

extension ModelContext {
    func fetchPreviewWorkout() -> Workout {
        let descriptor = FetchDescriptor<Workout>()
        return (try? fetch(descriptor).first) ?? Workout(name: "Preview Workout")
    }
}
