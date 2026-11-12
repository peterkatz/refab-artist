import SwiftUI

struct InflatablesPanel: View {
    @Binding var settings: InflatablesSettings
    @Binding var viewMode: InflatablesViewMode
    var plan: InflatablesPlan?
    var selectedPanelID: String?
    var onDiagnosticSelect: ((PlanDiagnostic) -> Void)? = nil

    private var rollWidthEnabled: Binding<Bool> {
        Binding(
            get: { settings.rollWidthMM != nil },
            set: { settings.rollWidthMM = $0 ? (settings.rollWidthMM ?? 600) : nil }
        )
    }

    private var rollWidth: Binding<Double> {
        Binding(
            get: { settings.rollWidthMM ?? 600 },
            set: { settings.rollWidthMM = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controlRow("Material") {
                Picker("Material", selection: $settings.material) {
                    ForEach(MaterialMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            controlRow("Join") {
                Picker("Join method", selection: $settings.joinMethod) {
                    ForEach(JoinMethod.allCases) { method in
                        Text(method.label).tag(method)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            sliderRow("Panel", value: $settings.targetPanelWidthMM, range: 20...500, unit: "mm", format: "%.0f")
            stepperRow("Max", value: $settings.maxPanelCount, range: 4...256, suffix: "panels")
            sliderRow("Seam", value: $settings.seamAllowanceMM, range: 0...40, unit: "mm", format: "%.1f")

            controlRow("Roll") {
                Toggle("", isOn: rollWidthEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                if settings.rollWidthMM != nil {
                    HStack(spacing: 8) {
                        Slider(value: rollWidth, in: 100...1500)
                        Text(String(format: "%.0f mm", rollWidth.wrappedValue))
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            }

            controlRow("Symmetry") {
                Toggle("", isOn: $settings.symmetryEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                Spacer()
            }

            if let plan {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Picker("View", selection: $viewMode) {
                        ForEach(InflatablesViewMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    Text("\(plan.panels.count) panels")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let preview = plan.preview {
                        Text("\(preview.inflatedMesh.triangleIndices.count / 3) preview triangles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Deviation max \(String(format: "%.1f", preview.maxDeviationMM)) mm, mean \(String(format: "%.1f", preview.meanDeviationMM)) mm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !plan.diagnostics.isEmpty {
                        ForEach(Array(plan.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            Button {
                                onDiagnosticSelect?(diagnostic)
                            } label: {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: selectedPanelID == diagnostic.panelID ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                                    Text(diagnostic.message)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                            .buttonStyle(.plain)
                            .disabled(diagnostic.panelID == nil)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func controlRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            content()
        }
    }

    private func sliderRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        unit: String,
        format: String
    ) -> some View {
        controlRow(label) {
            HStack(spacing: 8) {
                Slider(value: value, in: range)
                Text(String(format: "\(format) %@", value.wrappedValue, unit))
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
            }
        }
    }

    private func stepperRow(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, suffix: String) -> some View {
        controlRow(label) {
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue) \(suffix)")
                    .monospacedDigit()
            }
        }
    }
}
