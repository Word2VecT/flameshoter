// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <QRect>
#include <QString>
#include <memory>

class QWidget;

// Native preview materials stay separate from CaptureContext and exports.
class MacCaptureMaterial
{
public:
    MacCaptureMaterial(QWidget* host, int outsideOpacity);
    ~MacCaptureMaterial();
    void setSelection(const QRect& selection, bool visible);
    void setSelectionInfo(const QString& text, const QRect& bounds);
    void setErrorMessage(const QString& text);

private:
    struct Private;
    std::unique_ptr<Private> d;
};
