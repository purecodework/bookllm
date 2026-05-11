-- CreateIndex
CREATE INDEX "Page_chapterId_idx" ON "Page"("chapterId");

-- CreateIndex
CREATE INDEX "Page_bookId_translationStatus_idx" ON "Page"("bookId", "translationStatus");
