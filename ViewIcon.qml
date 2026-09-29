/*
Adapted from omatasks/ui/ViewIcon.qml.
MIT License

Copyright (c) 2026 Carmine Paolino

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

*/
import QtQuick
import qs.Commons

// Small, theme-colored list-view icons, drawn at their native size.
Item {
    id: root
    property string name: "today"
    property color color: Color.popups.text
    property int day: new Date().getDate()
    implicitWidth: Style.space(16)
    implicitHeight: Style.space(16)
    Canvas {
        id: canvas
        anchors.fill: parent
        onPaint: {
            var c = getContext("2d"), s = width / 24;
            c.reset(); c.scale(s, s); c.strokeStyle = root.color; c.fillStyle = root.color;
            c.lineWidth = 1.6; c.lineJoin = "round"; c.lineCap = "round";
            if (root.name === "inbox") {
                c.beginPath(); c.moveTo(5, 3); c.lineTo(19, 3); c.lineTo(22, 18); c.lineTo(21, 21); c.lineTo(3, 21); c.lineTo(2, 18); c.closePath(); c.stroke();
                c.beginPath(); c.moveTo(3, 14); c.lineTo(8, 14); c.lineTo(10, 17); c.lineTo(14, 17); c.lineTo(16, 14); c.lineTo(21, 14); c.stroke();
            } else {
                c.strokeRect(3, 3, 18, 18);
                if (root.name === "today") { c.beginPath(); c.moveTo(3, 8); c.lineTo(21, 8); c.stroke(); }
                else for (var y = 8; y <= 16; y += 4) for (var x = 7; x <= 17; x += 5) { c.beginPath(); c.arc(x, y, 1, 0, Math.PI * 2); c.fill(); }
            }
        }
        Connections { target: root; function onColorChanged() { canvas.requestPaint(); } function onNameChanged() { canvas.requestPaint(); } }
    }
    Text {
        visible: root.name === "today"
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height * 0.39
        text: root.day
        color: root.color
        font.family: Style.font.family
        font.pixelSize: root.height * 0.43
        font.bold: true
    }
}
