import PhotosUI
import SwiftData
import SwiftUI

private let gridColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

/// The Sticker tab's two subsections live here: creating a new sticker (camera or photo library,
/// via the toolbar "+" button) and browsing the cached gallery of previously-made stickers (the
/// grid itself).
struct StickerListView: View {
    @State private var viewModel: StickerListViewModel
    @Query(sort: \Sticker.createdAtMillis, order: .reverse) private var stickers: [Sticker]

    @State private var isSourceDialogPresented = false
    @State private var isCameraPresented = false
    @State private var isPhotoPickerPresented = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var editingImage: UIImage?
    @State private var isEditorPresented = false
    @State private var isClearAllDialogPresented = false

    private let container: AppContainer

    init(container: AppContainer) {
        self.container = container
        _viewModel = State(initialValue: StickerListViewModel(repository: container.stickerRepository))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if stickers.isEmpty {
                    ContentUnavailableView(
                        "No Stickers Yet",
                        systemImage: "face.smiling",
                        description: Text("Tap + to create one from a photo.")
                    )
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        ForEach(stickers) { sticker in
                            StickerThumbnail(image: viewModel.images[sticker.id])
                                .onAppear { viewModel.loadImageIfNeeded(for: sticker) }
                                .contextMenu {
                                    Button("Delete", role: .destructive) {
                                        viewModel.delete(sticker)
                                    }
                                }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Stickers")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isSourceDialogPresented = true
                    } label: {
                        Label("New Sticker", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button(role: .destructive) {
                        isClearAllDialogPresented = true
                    } label: {
                        Label("Clear All", systemImage: "trash")
                    }
                    .disabled(stickers.isEmpty)
                }
            }
            .confirmationDialog("New Sticker", isPresented: $isSourceDialogPresented, titleVisibility: .visible) {
                Button("Take Photo") { isCameraPresented = true }
                Button("Choose from Library") { isPhotoPickerPresented = true }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Clear all stickers?", isPresented: $isClearAllDialogPresented, titleVisibility: .visible
            ) {
                Button("Clear All", role: .destructive) { viewModel.clearAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes every saved sticker. This can't be undone.")
            }
            .fullScreenCover(isPresented: $isCameraPresented) {
                CameraCaptureView(
                    // Deliberately NOT setting `isEditorPresented = true` here too — toggling two
                    // `fullScreenCover` presentation flags on this same view in one update cycle
                    // is unreliable (SwiftUI can still be mid-dismissal of the camera cover when
                    // asked to present the next one, and the second presentation silently fails to
                    // show anything, confirmed on-device). `onChange` below waits for the camera
                    // cover's dismissal to actually complete before presenting the editor as a
                    // separate transition — same reason the "Choose from Library" path never hit
                    // this: `.task(id:)` there only runs after the picker has already dismissed.
                    onCapture: { image in
                        editingImage = image
                        isCameraPresented = false
                    },
                    onCancel: {
                        editingImage = nil
                        isCameraPresented = false
                    }
                )
                .ignoresSafeArea()
            }
            .onChange(of: isCameraPresented) { _, isPresented in
                guard !isPresented, editingImage != nil else { return }
                isEditorPresented = true
            }
            .photosPicker(isPresented: $isPhotoPickerPresented, selection: $selectedPhotoItem, matching: .images)
            .task(id: selectedPhotoItem) {
                guard let selectedPhotoItem else { return }
                defer { self.selectedPhotoItem = nil }
                if let data = try? await selectedPhotoItem.loadTransferable(type: Data.self),
                    let image = UIImage(data: data)
                {
                    editingImage = image
                    isEditorPresented = true
                }
            }
            .fullScreenCover(isPresented: $isEditorPresented) {
                if let editingImage {
                    NavigationStack {
                        StickerEditorView(image: editingImage, container: container)
                    }
                }
            }
        }
    }
}

private struct StickerThumbnail: View {
    let image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(6)
            } else {
                ProgressView()
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
