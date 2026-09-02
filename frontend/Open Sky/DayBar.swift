//
//  DayBar.swift
//  Open Sky
//
//  Created by Ben Kiev on 8/21/26.
//

import SwiftUI

struct DayBar: View {
    @Binding var selectedDayOffset: Int
    var dayCount: Int = 14

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0..<dayCount, id: \.self) { offset in
                        DayPill(offset: offset, isSelected: offset == selectedDayOffset) {
                            selectedDayOffset = offset
                        }
                        .id(offset)
                    }
                }
                .padding(.horizontal, 4)
            }
            .onAppear {
                proxy.scrollTo(selectedDayOffset, anchor: .center)
            }
            .onChange(of: selectedDayOffset) { _, newValue in
                withAnimation {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}

struct DayPill: View {
    let offset: Int
    let isSelected: Bool
    let action: () -> Void

    private var date: Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(offset == 0 ? "Today" : date.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.caption)
                    .fontWeight(isSelected ? .bold : .regular)
                Text(date.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}
