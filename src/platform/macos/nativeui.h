// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <QColor>
#include <QObject>
#include <QRect>
#include <QStringList>
#include <QVector>
#include <functional>
#include <memory>

class QWidget;
class CaptureToolButton;

// The AppKit surface forwards actions into the unmodified Flameshot tools.
class MacCaptureBar : public QObject
{
public:
    MacCaptureBar(QWidget* host, const QVector<CaptureToolButton*>& tools,
                  QObject* parent);
    ~MacCaptureBar() override;
    void setVisible(bool visible);
    bool isVisible() const;
    bool contains(const QPoint& point) const;
    void setSelection(const QRect& selection);
    void setActiveTool(int type);
    void setColor(const QColor& color);
    void setThickness(int thickness);
    void setLayers(const QStringList& names, int selected);
    void toggleInspector();
    void showInspector();

    std::function<void(const QColor&)> colorChanged;
    std::function<void(int)> thicknessChanged;
    std::function<void(int)> layerSelected;
    std::function<void(int)> layerMoved;
    std::function<void(const QString&)> fontChanged;
    std::function<void(const QString&, int)> textStyleChanged;
    std::function<void()> deleteLayer;
    std::function<void(bool)> hoverChanged;

private:
    struct Private;
    std::unique_ptr<Private> d;
};

namespace MacUI {
void installMenu();
bool setLaunchAtLogin(bool enabled);
bool ensureScreenCaptureAccess();
QColor systemAccentColor();
void showPreferences();
void showLauncher();
void showDemo();
void showAbout();
bool confirmDiscard();
}
