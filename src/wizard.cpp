/*
    Copyright (C) 2021  Aaron Feng

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

#include "mainwindow.h"
#include "ui_mainwindow.h"
#include "wizard_preview.h"

#include <algorithm>

#include <QAbstractButton>
#include <QAbstractItemView>
#include <QButtonGroup>
#include <QCheckBox>
#include <QClipboard>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDateTime>
#include <QDirIterator>
#include <QDoubleSpinBox>
#include <QDynamicPropertyChangeEvent>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QFocusEvent>
#include <QFontMetrics>
#include <QFontDatabase>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QImageReader>
#include <QInputDialog>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QKeyEvent>
#include <QKeySequence>
#include <QListWidget>
#include <QLineEdit>
#include <QMouseEvent>
#include <QMenu>
#include <QPainter>
#include <QProcess>
#include <QPointer>
#include <QPropertyAnimation>
#include <QRadioButton>
#include <QRegularExpression>
#include <QScrollArea>
#include <QShortcut>
#include <QSignalBlocker>
#include <QSlider>
#include <QSpinBox>
#include <QStackedLayout>
#include <QStyleOptionButton>
#include <QStyleHints>
#include <QStyledItemDelegate>
#include <QSvgRenderer>
#include <QTextBrowser>
#include <QVariantAnimation>
#include <QVBoxLayout>
#include <QUuid>
#include <cstdio>
#include <cmath>
#include <functional>
#include <limits>
#include <memory>

namespace {
int qMin(int a,int b){return a<b?a:b;}int qMin(std::initializer_list<int> values){int result=std::numeric_limits<int>::max();for(int value:values)result=value<result?value:result;return result;}
struct Theme
{
    QString bg, sidebar, card, border, text, subtext, accent, accent2, accentTint;
    QString success, danger, fieldBg;
    bool dark = false;
};

struct MediaResult
{
    QString cacheKey;
    QImage image;
    QSize size;
    qint64 byteSize = -1;
    double durationSeconds = -1;
    qint64 frameCount = -1;
    qint64 audioBytes = 0;
};

double jsonNumber(const QJsonValue &value)
{
    return value.isDouble()?value.toDouble():value.toString().toDouble();
}

double frameRate(const QString &fraction)
{
    const QStringList parts=fraction.split('/');if(parts.size()!=2)return fraction.toDouble();const double denominator=parts[1].toDouble();return denominator>0?parts[0].toDouble()/denominator:0;
}

QString mediaCacheKey(const QString &path)
{
    const QFileInfo info(path);
    return path+QChar(0)+QString::number(info.lastModified().toMSecsSinceEpoch());
}

bool waitForProcess(QProcess &process,int timeoutMs)
{
    if(!process.waitForStarted(2000)||!process.waitForFinished(timeoutMs)){
        process.kill();process.waitForFinished();return false;
    }
    return process.exitStatus()==QProcess::NormalExit&&process.exitCode()==0;
}

MediaResult readMedia(const QString &path,int type,const QString &toolsPath)
{
    MediaResult result;const QFileInfo info(path);result.cacheKey=mediaCacheKey(path);result.byteSize=info.exists()?info.size():-1;
    if(type==2){
        QProcess probe;probe.start(toolsPath+"/ffprobe_waifu2xEX",{"-v","error","-show_entries","stream=codec_type,width,height,duration,nb_frames,avg_frame_rate,bit_rate:format=duration","-of","json",path});
        if(waitForProcess(probe,15000)){const QJsonObject root=QJsonDocument::fromJson(probe.readAllStandardOutput()).object();result.durationSeconds=jsonNumber(root.value("format").toObject().value("duration"));for(const QJsonValue &value:root.value("streams").toArray()){const QJsonObject stream=value.toObject();const QString kind=stream.value("codec_type").toString();if(kind=="video"&&!result.size.isValid()){result.size=QSize(stream.value("width").toInt(),stream.value("height").toInt());const double streamDuration=jsonNumber(stream.value("duration"));if(result.durationSeconds<=0)result.durationSeconds=streamDuration;result.frameCount=qRound64(jsonNumber(stream.value("nb_frames")));if(result.frameCount<=0&&result.durationSeconds>0)result.frameCount=qRound64(result.durationSeconds*frameRate(stream.value("avg_frame_rate").toString()));}else if(kind=="audio"){const double streamDuration=jsonNumber(stream.value("duration")),bitrate=jsonNumber(stream.value("bit_rate"));if(bitrate>0)result.audioBytes+=qRound64(bitrate*(streamDuration>0?streamDuration:result.durationSeconds)/8.0);}}}
        QProcess ffmpeg;QStringList args={"-v","error"};if(result.durationSeconds>0.5)args<<"-ss"<<"0.5";args<<"-i"<<path<<"-frames:v"<<"1"<<"-vf"<<"scale=240:-1"<<"-f"<<"image2pipe"<<"-vcodec"<<"png"<<"-";ffmpeg.start(toolsPath+"/ffmpeg_waifu2xEX",args);if(waitForProcess(ffmpeg,15000))result.image.loadFromData(ffmpeg.readAllStandardOutput(),"PNG");
    }else{
        QImageReader reader(path);reader.setAutoTransform(true);result.size=reader.size();if(type==1)result.frameCount=reader.imageCount();if(result.size.isValid())reader.setScaledSize(result.size.scaled(240,240,Qt::KeepAspectRatio));result.image=reader.read();
    }
    return result;
}

struct PreviewSource
{
    QImage crop;
    QSize sourceSize;
    QString inputPath,error;
};

Theme wizardTheme()
{
    const QString forced = qEnvironmentVariable("W2X_SCHEME").toLower();
    const QString appearance=QSettings().value("appearance","system").toString();
    const bool dark = forced == "dark" || (forced.isEmpty() && (appearance=="dark" || (appearance=="system" && qApp->styleHints()->colorScheme() == Qt::ColorScheme::Dark)));
    if(dark)
        return {"#16171B", "#1C1D22", "#212227", "#2E3036", "#F2F2F5", "#9A9BA3",
                "#0A84FF", "#5E5CE6", "#173451", "#32D74B", "#FF453A", "#282A30", true};
    return {"#F4F5F8", "#ECEEF5", "#FFFFFF", "#DDE0E8", "#1D1D1F", "#6E6E73",
            "#0A84FF", "#5E5CE6", "#EAF4FF", "#248A3D", "#D70015", "#F8F9FB", false};
}

QString firstOutputFile(const QString &source, const QString &outputFolder)
{
    const QFileInfo input(source);
    const QString folder=outputFolder.isEmpty()?input.absolutePath():outputFolder;
    QFileInfo newest;
    QDirIterator files(folder,QDir::Files,QDirIterator::Subdirectories);
    while(files.hasNext()){
        const QFileInfo candidate(files.next());
        if(candidate.absoluteFilePath()==input.absoluteFilePath()||candidate.size()<=0||candidate.absoluteFilePath().contains("W2xEX",Qt::CaseInsensitive))continue;
        if(candidate.completeBaseName()!=input.completeBaseName()&&!candidate.completeBaseName().startsWith(input.completeBaseName()+"_"))continue;
        if(!newest.exists()||candidate.lastModified()>newest.lastModified())newest=candidate;
    }
    return newest.absoluteFilePath();
}

QString failureLogTail(const QString &log)
{
    const QStringList lines=log.split('\n',Qt::SkipEmptyParts);
    for(auto it=lines.crbegin();it!=lines.crend();++it)
        if(it->contains(QRegularExpression("failed|error|unable|can't",QRegularExpression::CaseInsensitiveOption)))return it->trimmed().left(320);
    return lines.isEmpty()?QString():lines.constLast().trimmed().left(320);
}

QPixmap svgPixmap(const QString &path, const QColor &color, QSize size)
{
    QPixmap source(size);
    source.fill(Qt::transparent);
    QPainter sourcePainter(&source);
    QSvgRenderer(path).render(&sourcePainter, QRect(QPoint(), size));
    sourcePainter.end();
    QPainter painter(&source);
    painter.setCompositionMode(QPainter::CompositionMode_SourceIn);
    painter.fillRect(source.rect(), color);
    return source;
}

QString wizardStyle(const Theme &t)
{
    QString qss = QString::fromUtf8(R"(
QWidget#wizardRoot { background: qlineargradient(x1:0,y1:0,x2:0,y2:1,stop:0 $BG,stop:1 $BG2); color: $TEXT; font-family: -apple-system, ".AppleSystemUIFont"; font-size: 13px; }
QWidget#advancedPage { background: $BG; }
QWidget#sidebar { background: transparent; border-right: 1px solid $BORDER; }
QLabel#appName { color: $TEXT; font-size: 16px; font-weight: 600; }
QLabel#tagline, QLabel#subtitle, QLabel#caption, QLabel#helper { color: $SUBTEXT; font-size: 11.5px; }
QLabel#pageTitle { color: $TEXT; font-size: 28px; font-weight: 700; }
QLabel#sectionHeader { color: $SUBTEXT; font-size: 11.5px; font-weight: 650; }
QLabel#cardTitle { color: $TEXT; font-size: 17px; font-weight: 650; }
QWidget#headerBand { background: transparent; }
QLabel#headerChip, QLabel#sessionChip { color: $ACCENT; font-size: 11.5px; font-weight: 650; padding: 5px 9px; background: $TINT; border: 1px solid $BORDER; border-radius: 12px; }
QFrame#headerHairline { min-height: 1px; max-height: 1px; border: 0; background: qlineargradient(x1:0,y1:0,x2:1,y2:0,stop:0 $ACCENT,stop:.45 $ACCENT2,stop:1 transparent); }
QFrame#card, QWidget#card { background: $CARD; border: 1px solid $BORDER; border-radius: 18px; }
QWidget#dropCard { background: $CARD; border: 2px dashed $BORDER; border-radius: 18px; }
QWidget#dropCard[dragActive="true"] { background: $TINT; border-color: $ACCENT; }
QPushButton { min-height: 36px; padding: 0 14px; color: $TEXT; border: 1px solid transparent; border-radius: 10px; background: $BORDER; }
QPushButton:hover { border-color: $ACCENT; }
QPushButton:pressed { background: $TINT; }
QPushButton[keyboardFocus="true"] { border: 2px solid $ACCENT; }
QPushButton:disabled { color: $SUBTEXT; background: $BG; }
QPushButton#primary { min-height: 40px; color: white; background: qlineargradient(x1:0,y1:0,x2:1,y2:0,stop:0 $ACCENT,stop:1 $ACCENT2); font-weight: 650; }
QPushButton#primary:hover { border-color: rgba(255,255,255,150); }
QPushButton#engineCard, QPushButton#photosCard { padding: 0; text-align: left; background: $CARD; border: 1px solid $BORDER; border-radius: 18px; }
QPushButton#engineCard:hover, QPushButton#photosCard:hover { border-color: $ACCENT; }
QPushButton#engineCard:checked, QPushButton#photosCard:checked { background: $TINT; border: 1px solid $BORDER; border-top: 2px solid $ACCENT; }
QPushButton#engineCard[keyboardFocus="true"], QPushButton#photosCard[keyboardFocus="true"] { border: 2px solid $ACCENT; }
QLabel#engineTitle { color: $TEXT; font-size: 17px; font-weight: 650; background: transparent; }
QLabel#engineDescription { color: $SUBTEXT; font-size: 11.5px; background: transparent; }
QLabel#pill { color: $SUBTEXT; font-size: 11.5px; padding: 2px 7px; background: $BG; border-radius: 8px; }
QLabel#recommendedPill { color: $SUCCESS; font-size: 11.5px; padding: 2px 7px; background: $TINT; border-radius: 8px; }
QLabel#engineCheck { color: white; background: $ACCENT; border-radius: 9px; font-size: 12px; font-weight: 700; }
QPushButton#engineCard QLabel#engineTitle, QPushButton#photosCard QLabel#engineTitle { color: $TEXT; }
QPushButton#engineCard QLabel#engineDescription, QPushButton#photosCard QLabel#engineDescription,
QPushButton#engineCard QLabel#helper, QPushButton#photosCard QLabel#helper,
QPushButton#engineCard QLabel#caption, QPushButton#photosCard QLabel#caption { color: $SUBTEXT; }
QPushButton#engineCard QLabel#pill, QPushButton#photosCard QLabel#pill { color: $SUBTEXT; }
QPushButton#engineCard QLabel#recommendedPill, QPushButton#photosCard QLabel#recommendedPill { color: $SUCCESS; }
QPushButton#engineCard QLabel#engineCheck, QPushButton#photosCard QLabel#engineCheck { color: white; }
QPushButton[advancedHeader="true"] { min-height: 40px; padding: 0 6px; background: transparent; border: 0; text-align: left; }
QPushButton[advancedHeader="true"]:hover { background: $TINT; border: 0; }
QLabel#advancedChevron { color: $SUBTEXT; font-size: 15px; background: transparent; }
QLabel#advancedHeaderTitle { color: $TEXT; font-size: 13px; font-weight: 650; background: transparent; }
QLabel#advancedHeaderSubtitle { color: $SUBTEXT; font-size: 11.5px; background: transparent; }
QPushButton#segment { min-height: 32px; padding: 0 8px; border-radius: 9px; background: $BG; }
QPushButton#segment:checked { color: white; background: qlineargradient(x1:0,y1:0,x2:1,y2:0,stop:0 $ACCENT,stop:1 $ACCENT2); }
QPushButton#sideSettings { background: transparent; text-align: left; color: $TEXT; }
QPushButton#sideSettings:hover { background: $CARD; border-color: transparent; }
QLabel#gpuPill { color: $SUBTEXT; background: $CARD; border: 1px solid $BORDER; border-radius: 12px; padding: 5px 8px; font-size: 11.5px; }
QListWidget { color: $TEXT; background: transparent; border: 0; outline: 0; }
QListWidget::item { background: transparent; border: 0; }
QWidget#advancedTabs { background: $FIELD; border: 1px solid $BORDER; border-radius: 16px; }
QPushButton#advancedTab { min-height: 42px; padding: 0 10px; border: 0; border-radius: 11px; background: transparent; text-align: left; }
QPushButton#advancedTab:hover, QPushButton#advancedTab:checked { color: $ACCENT; background: $TINT; }
QFrame#advancedFooterLine { min-height: 1px; max-height: 1px; background: $BORDER; border: 0; }
QTableView { color: $TEXT; background: $CARD; alternate-background-color: $BG; border: 1px solid $BORDER; border-radius: 10px; gridline-color: transparent; }
QTableView::item:selected { background: $TINT; color: $TEXT; }
QHeaderView::section { color: $SUBTEXT; background: $BG; border: 0; border-bottom: 1px solid $BORDER; padding: 7px; }
QComboBox, QSpinBox, QDoubleSpinBox, QLineEdit { color: $TEXT; background: $FIELD; border: 1px solid $BORDER; border-radius: 8px; padding: 0 8px; selection-background-color: $ACCENT; }
QComboBox QAbstractItemView { color: $TEXT; background: $CARD; border: 1px solid $BORDER; border-radius: 8px; outline: 0; padding: 6px; selection-color: $ACCENT; selection-background-color: $TINT; }
QComboBox QAbstractItemView::item { min-height: 24px; padding: 6px; }
QComboBox QAbstractItemView::item:selected { color: $ACCENT; background: $TINT; }
QRadioButton, QCheckBox, QGroupBox { color: $TEXT; background: transparent; }
QSlider::groove:horizontal { height: 4px; background: $BORDER; border-radius: 2px; }
QSlider::handle:horizontal { width: 16px; margin: -6px 0; background: $ACCENT; border-radius: 8px; }
QProgressBar { min-height: 10px; max-height: 10px; border: 0; border-radius: 5px; background: $BORDER; text-align: center; }
QProgressBar::chunk { border-radius: 5px; background: qlineargradient(x1:0,y1:0,x2:1,y2:0,stop:0 $ACCENT,stop:1 $ACCENT2); }
QLabel#progressMeta, QLabel[progressMeta="true"] { color: $SUBTEXT; font-size: 11.5px; background: transparent; }
QPushButton#dangerSecondary { color: $DANGER; background: transparent; border: 1px solid $DANGER; }
QPushButton#dangerSecondary:hover { background: $TINT; }
QPushButton#detailsButton { color: $ACCENT; background: transparent; padding: 0; text-align: left; }
QTextBrowser#detailsLog { color: $TEXT; background: $FIELD; border: 1px solid $BORDER; border-radius: 10px; font-family: Menlo, Monaco, monospace; font-size: 11.5px; }
QScrollArea, QAbstractScrollArea, QAbstractScrollArea::viewport { background: transparent; border: 0; }
QScrollBar:vertical { width: 9px; background: transparent; }
QScrollBar::handle:vertical { min-height: 28px; background: $BORDER; border-radius: 4px; }
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
QLabel#doneMark { color: white; background: $SUCCESS; border-radius: 36px; font-size: 38px; font-weight: 650; }
QLabel#doneTitle { color: $TEXT; font-size: 22px; font-weight: 650; }
QLabel#doneSubtitle { color: $SUBTEXT; font-size: 13px; }
QWidget#typeTile { background: $FIELD; border: 1px solid $BORDER; border-radius: 12px; }
QLabel#typeTileTitle { color: $TEXT; font-size: 13px; font-weight: 650; }
QLabel#estimateValue { color: $TEXT; font-size: 17px; font-weight: 650; }
QPushButton#recentTile { min-height: 96px; padding: 8px; text-align: left; background: $FIELD; border: 1px solid $BORDER; border-radius: 12px; }
QPushButton#textButton { color: $ACCENT; background: transparent; border: 0; padding: 0 4px; }
QWidget#fileFooter { background: $FIELD; border-radius: 10px; }
QWidget#flowNode { background: $FIELD; border: 1px solid $BORDER; border-radius: 14px; }
QWidget#resultCard { background: $FIELD; border: 1px solid $BORDER; border-radius: 14px; }
QWidget#resultCard[failed="true"] { background: $TINT; border-color: $DANGER; }
QToolTip { color: $TEXT; background: $CARD; border: 1px solid $BORDER; padding: 5px; }
)");
    qss.replace("$SIDEBAR", t.sidebar).replace("$ACCENT2", t.accent2).replace("$ACCENT", t.accent)
       .replace("$SUCCESS", t.success).replace("$SUBTEXT", t.subtext).replace("$BORDER", t.border)
       .replace("$DANGER", t.danger).replace("$FIELD", t.fieldBg).replace("$CARD", t.card)
       .replace("$TINT", t.accentTint).replace("$TEXT", t.text).replace("$BG2", t.dark ? "#121317" : "#EEF0F7").replace("$BG", t.dark ? "#17181D" : "#F6F7FB");
    return qss;
}

class SidebarPanel final : public QWidget
{
public: using QWidget::QWidget;
protected:
    void paintEvent(QPaintEvent *) override
    {
        const Theme t=wizardTheme(); QPainter p(this);
        QLinearGradient base(0,0,0,height());base.setColorAt(0,QColor(t.sidebar).lighter(t.dark?108:103));base.setColorAt(1,QColor(t.sidebar).darker(t.dark?108:103));p.fillRect(rect(),base);
        QRadialGradient glow(QPointF(0,0),220);QColor a(t.accent);a.setAlpha(t.dark?42:28);glow.setColorAt(0,a);a.setAlpha(0);glow.setColorAt(1,a);p.fillRect(rect(),glow);
    }
};

class AppMark final : public QWidget
{
public:
    explicit AppMark(QWidget *parent = nullptr, int side = 40) : QWidget(parent) { setFixedSize(side, side); }
protected:
    void paintEvent(QPaintEvent *) override
    {
        const qreal ratio=devicePixelRatioF();
        QPixmap icon(":/wizard/icons/wizard/appicon.png");
        icon=icon.scaled(size()*ratio,Qt::KeepAspectRatio,Qt::SmoothTransformation);
        icon.setDevicePixelRatio(ratio);
        QPainter painter(this);
        painter.drawPixmap(0,0,icon);
    }
};

class HeroArt final : public QWidget
{
public: explicit HeroArt(QWidget *parent=nullptr):QWidget(parent){setFixedSize(104,84);}
protected:void paintEvent(QPaintEvent *) override
    {
        QPainter p(this);p.setRenderHint(QPainter::Antialiasing);const QColor accent=palette().color(QPalette::Highlight);p.setPen(Qt::NoPen);QColor shadow=accent;shadow.setAlpha(35);p.setBrush(shadow);p.drawRoundedRect(QRectF(18,20,66,50),14,14);shadow.setAlpha(65);p.setBrush(shadow);p.drawRoundedRect(QRectF(25,13,66,50),14,14);QLinearGradient g(30,8,88,64);g.setColorAt(0,QColor("#0A84FF"));g.setColorAt(1,QColor("#5E5CE6"));p.setBrush(g);p.drawRoundedRect(QRectF(31,7,66,50),14,14);p.setPen(QPen(Qt::white,3,Qt::SolidLine,Qt::RoundCap,Qt::RoundJoin));p.drawLine(QPointF(64,43),QPointF(64,22));p.drawLine(QPointF(55,31),QPointF(64,22));p.drawLine(QPointF(73,31),QPointF(64,22));
    }
};

class IconTile final : public QWidget
{
public:
    IconTile(QString path, int side, QWidget *parent = nullptr) : QWidget(parent), m_path(std::move(path)) { setFixedSize(side, side); }
protected:
    void paintEvent(QPaintEvent *) override
    {
        QPainter p(this); p.setRenderHint(QPainter::Antialiasing);
        QLinearGradient g(rect().topLeft(), rect().bottomRight());
        g.setColorAt(0, QColor("#0A84FF")); g.setColorAt(1, QColor("#5E5CE6"));
        p.setPen(Qt::NoPen); p.setBrush(g); p.drawRoundedRect(rect().adjusted(1,1,-1,-1), width() / 4.0, width() / 4.0);
        const int inset = qMax(8, width() / 4);
        p.drawPixmap(QRect(inset, inset, width()-2*inset, height()-2*inset), svgPixmap(m_path, Qt::white, QSize(48,48)));
    }
private:
    QString m_path;
};

class StepButton final : public QPushButton
{
    Q_OBJECT
    Q_PROPERTY(qreal connector READ connector WRITE setConnector)
public:
    StepButton(int number, QString title, QString caption, bool first, bool last, QWidget *parent)
        : QPushButton(title,parent), m_number(number), m_title(std::move(title)), m_caption(std::move(caption)), m_first(first), m_last(last)
    { setCheckable(true); setFixedHeight(66); setCursor(Qt::PointingHandCursor); setFocusPolicy(Qt::TabFocus);m_pulseTimer=new QTimer(this);m_pulseTimer->setInterval(45);connect(m_pulseTimer,&QTimer::timeout,this,[this]{m_pulsePhase=(m_pulsePhase+1)%24;update();}); }
    qreal connector() const{return m_connector;} void setConnector(qreal v){m_connector=v;update();}
    void setRunning(bool running){m_running=running;if(running&&!qEnvironmentVariableIsSet("W2X_SNAPSHOT_DIR"))m_pulseTimer->start();else m_pulseTimer->stop();update();}
protected:
    bool event(QEvent *event) override
    {
        if(event->type()==QEvent::DynamicPropertyChange&&static_cast<QDynamicPropertyChangeEvent*>(event)->propertyName()=="stepState"){
            const qreal target=property("stepState").toInt()>=2?1.0:0.0;auto *a=new QPropertyAnimation(this,"connector",this);a->setStartValue(m_connector);a->setEndValue(target);a->setDuration(qEnvironmentVariableIsSet("W2X_SNAPSHOT_DIR")?0:180);a->setEasingCurve(QEasingCurve::OutCubic);a->start(QAbstractAnimation::DeleteWhenStopped);
        }return QPushButton::event(event);
    }
    void paintEvent(QPaintEvent *) override
    {
        QPainter p(this); p.setRenderHint(QPainter::Antialiasing);
        const int state = property("stepState").toInt();
        const QColor accent = palette().color(QPalette::Highlight), border = palette().color(QPalette::Mid);
        const QColor text = palette().color(QPalette::WindowText), sub = palette().color(QPalette::PlaceholderText);
        if(underMouse() || state == 1) { p.setPen(Qt::NoPen); p.setBrush(palette().color(QPalette::Base)); p.drawRoundedRect(rect(), 12, 12); }
        const int x = 16, cy = height()/2;
        p.setPen(QPen(state > 0 ? accent : border, 2));
        if(!m_first) p.drawLine(x, 0, x, cy-14);
        p.setPen(QPen(border,2));if(!m_last)p.drawLine(x,cy+14,x,height());
        if(!m_last&&m_connector>0){p.setPen(QPen(accent,2));p.drawLine(QPointF(x,cy+14),QPointF(x,cy+14+(height()-cy-14)*m_connector));}
        if(state == 1) {
            if(m_running){QColor halo=accent;halo.setAlpha(20+qRound(25*qAbs(12-m_pulsePhase)/12.0));p.setBrush(halo);p.setPen(Qt::NoPen);p.drawEllipse(QPointF(x,cy),17+m_pulsePhase%5,17+m_pulsePhase%5);}
            QLinearGradient g(x-14, cy-14, x+14, cy+14); g.setColorAt(0, QColor("#0A84FF")); g.setColorAt(1, QColor("#5E5CE6"));
            p.setPen(Qt::NoPen); p.setBrush(g); p.drawEllipse(QPointF(x,cy), 14, 14);
        } else {
            p.setBrush(state == 2 ? accent : palette().color(QPalette::AlternateBase));
            p.setPen(QPen(state == 2 ? accent : border, 1.5)); p.drawEllipse(QPointF(x,cy), 13, 13);
        }
        p.setPen(state > 0 ? Qt::white : sub); p.setFont(QFont(font().family(), 11, QFont::DemiBold));
        p.drawText(QRect(x-13,cy-13,26,26), Qt::AlignCenter, state == 2 ? QString::fromUtf8("✓") : QString::number(m_number));
        p.setPen(state == 1 ? accent : text); p.setFont(QFont(font().family(), 13, state == 1 ? QFont::DemiBold : QFont::Normal));
        const bool showCaption = height() >= 60; p.drawText(QRect(42, showCaption ? 13 : cy-10, width()-48, 20), Qt::AlignVCenter, m_title);
        if(showCaption){ p.setPen(sub); p.setFont(QFont(font().family(), 10));
        p.drawText(QRect(42, 34, width()-48, 18), Qt::AlignVCenter, m_caption); }
    }
private:
    int m_number; QString m_title, m_caption; bool m_first, m_last; qreal m_connector=0;QTimer *m_pulseTimer=nullptr;int m_pulsePhase=0;bool m_running=false;
};

class AdvancedButton final : public QPushButton
{
public: using QPushButton::QPushButton;
protected:void paintEvent(QPaintEvent *event) override{QPushButton::paintEvent(event);if(!property("changed").toBool())return;QPainter painter(this);painter.setRenderHint(QPainter::Antialiasing);painter.setPen(Qt::NoPen);painter.setBrush(QColor("#FF9F0A"));painter.drawEllipse(QPoint(width()-9,9),4,4);}
};

class ToggleSwitch final : public QAbstractButton
{
    Q_OBJECT
    Q_PROPERTY(qreal offset READ offset WRITE setOffset)
public:
    explicit ToggleSwitch(QWidget *parent = nullptr) : QAbstractButton(parent)
    {
        setCheckable(true); setCursor(Qt::PointingHandCursor); setFixedSize(44,26);
        connect(this, &QAbstractButton::toggled, this, [this](bool on) {
            auto *a = new QPropertyAnimation(this, "offset", this);
            a->setStartValue(m_offset); a->setEndValue(on ? 1.0 : 0.0);
            a->setDuration(qEnvironmentVariableIsSet("W2X_SNAPSHOT_DIR") ? 0 : 150);
            a->setEasingCurve(QEasingCurve::OutCubic); a->start(QAbstractAnimation::DeleteWhenStopped);
        });
    }
    qreal offset() const { return m_offset; }
    void setOffset(qreal v) { m_offset = v; update(); }
protected:
    void paintEvent(QPaintEvent *) override
    {
        QPainter p(this); p.setRenderHint(QPainter::Antialiasing);
        p.setPen(Qt::NoPen); p.setBrush(isChecked() ? palette().color(QPalette::Highlight) : palette().color(QPalette::Mid));
        p.drawRoundedRect(rect(), 13, 13);
        const qreal x = 3 + m_offset * 18;
        p.setBrush(Qt::white); p.drawEllipse(QRectF(x,3,20,20));
    }
private: qreal m_offset = 0;
};

class ProgressRing final : public QWidget
{
    Q_OBJECT
    Q_PROPERTY(qreal value READ value WRITE setValue)
public:
    explicit ProgressRing(QWidget *parent = nullptr) : QWidget(parent) { setFixedSize(120,120); }
    qreal value() const { return m_value; }
    void animateTo(int value)
    {
        auto *a = new QPropertyAnimation(this, "value", this); a->setStartValue(m_value); a->setEndValue(value);
        a->setDuration(qEnvironmentVariableIsSet("W2X_SNAPSHOT_DIR") ? 0 : 150); a->setEasingCurve(QEasingCurve::OutCubic);
        a->start(QAbstractAnimation::DeleteWhenStopped);
    }
    void setValue(qreal value) { m_value = value; update(); }
protected:
    void paintEvent(QPaintEvent *) override
    {
        QPainter p(this); p.setRenderHint(QPainter::Antialiasing);
        QRectF arc = rect().adjusted(9,9,-9,-9);
        p.setPen(QPen(palette().color(QPalette::Mid), 9, Qt::SolidLine, Qt::RoundCap)); p.drawArc(arc, 0, 360*16);
        QConicalGradient g(rect().center(), -90); g.setColorAt(0, QColor("#0A84FF")); g.setColorAt(.65, QColor("#5E5CE6")); g.setColorAt(1, QColor("#0A84FF"));
        p.setPen(QPen(QBrush(g), 9, Qt::SolidLine, Qt::RoundCap)); p.drawArc(arc, 90*16, -qRound(m_value*3.6*16));
        p.setPen(palette().color(QPalette::WindowText)); p.setFont(QFont(font().family(), 22, QFont::DemiBold));
        p.drawText(rect(), Qt::AlignCenter, QString::number(qRound(m_value)) + "%");
    }
private: qreal m_value = 0;
};

enum ItemRole { PathRole = Qt::UserRole + 1, TypeRole, SizeRole, StatusRole, RowRole, ProgressRole };

class FileDelegate final : public QStyledItemDelegate
{
public:
    explicit FileDelegate(QObject *parent = nullptr) : QStyledItemDelegate(parent) {}
    std::function<void(int,int)> remove;
    std::function<void(const QString &)> reveal;
    QSize sizeHint(const QStyleOptionViewItem &option, const QModelIndex &) const override
    { const int width=option.widget ? option.widget->property("gridCellWidth").toInt() : 0; return option.widget && option.widget->property("statusMode").toBool() ? QSize(500,62) : QSize(width>0?width:152,218); }
    void paint(QPainter *p, const QStyleOptionViewItem &o, const QModelIndex &i) const override
    {
        p->save(); p->setRenderHint(QPainter::Antialiasing);
        const bool statusMode = o.widget && o.widget->property("statusMode").toBool();
        const QPalette palette = o.widget ? o.widget->palette() : o.palette;
        const QColor field(o.widget ? o.widget->property("fieldColor").toString() : QString()), tokenBorder(o.widget ? o.widget->property("borderColor").toString() : QString());
        const QColor card = statusMode && field.isValid() ? field : palette.color(QPalette::Base), border = tokenBorder.isValid() ? tokenBorder : palette.color(QPalette::Mid);
        const QColor text = palette.color(QPalette::WindowText), sub = palette.color(QPalette::PlaceholderText), accent = palette.color(QPalette::Highlight);
        QRect r = o.rect.adjusted(4,4,-4,-4); p->setPen(QPen(statusMode ? border : (o.state & QStyle::State_Selected) ? accent : border, 1)); p->setBrush(card); p->drawRoundedRect(r, 12, 12);
        const QPixmap pix = qvariant_cast<QPixmap>(i.data(Qt::DecorationRole));
        if(statusMode) {
            QRect thumb(r.left()+8,r.top()+(r.height()-44)/2,44,44); { const QPixmap fit=pix.scaled(thumb.size(),Qt::KeepAspectRatio,Qt::SmoothTransformation); QRect target(QPoint(0,0),fit.size()); target.moveCenter(thumb.center()); p->drawPixmap(target,fit); }
            const int textLeft=thumb.left()+52, textWidth=r.right()-textLeft-12;
            p->setPen(text); p->setFont(QFont(o.font.family(),12,QFont::DemiBold)); p->drawText(QRect(textLeft,r.top()+8,textWidth,20), Qt::AlignVCenter, o.fontMetrics.elidedText(i.data(Qt::DisplayRole).toString(),Qt::ElideMiddle,textWidth));
            const QString status=i.data(StatusRole).toString(); QColor dot=sub; if(status.contains("Processing",Qt::CaseInsensitive)) dot=accent; else if(status.contains("Finished",Qt::CaseInsensitive)) dot=QColor("#32C759"); else if(status.contains("Failed",Qt::CaseInsensitive)) dot=QColor("#FF453A");
            p->setPen(Qt::NoPen); p->setBrush(dot); p->drawEllipse(QPoint(textLeft+4,r.top()+38),4,4); p->setPen(sub); p->setFont(QFont(o.font.family(),10)); p->drawText(QRect(textLeft+14,r.top()+29,textWidth-14,18),Qt::AlignVCenter,status.isEmpty()?QObject::tr("Waiting"):status);
            if(status.contains("Processing",Qt::CaseInsensitive)){QRect bar(textLeft,r.bottom()-8,textWidth,3);p->setPen(Qt::NoPen);p->setBrush(border);p->drawRoundedRect(bar,2,2);bar.setWidth(qRound(bar.width()*qBound(0,i.data(ProgressRole).toInt(),100)/100.0));p->setBrush(accent);p->drawRoundedRect(bar,2,2);}
        } else {
            QRect thumb(r.left()+10,r.top()+10,r.width()-20,112); p->setPen(Qt::NoPen); p->setBrush(o.palette.color(QPalette::Window)); p->drawRoundedRect(thumb,9,9);
            { const QPixmap fit=pix.scaled(thumb.size(),Qt::KeepAspectRatio,Qt::SmoothTransformation); QRect target(QPoint(0,0),fit.size()); target.moveCenter(thumb.center()); p->drawPixmap(target,fit); }
            const QString type=i.data(TypeRole).toString(); QRect badge(thumb.left()+6,thumb.bottom()-23,34,17); p->setBrush(QColor(0,0,0,145)); p->drawRoundedRect(badge,7,7); p->setPen(Qt::white); p->setFont(QFont(o.font.family(),9,QFont::DemiBold)); p->drawText(badge,Qt::AlignCenter,type);
            p->setPen(text); p->setFont(QFont(o.font.family(),11,QFont::DemiBold)); p->drawText(QRect(r.left()+9,r.top()+128,r.width()-18,18),Qt::AlignCenter,o.fontMetrics.elidedText(i.data(Qt::DisplayRole).toString(),Qt::ElideMiddle,r.width()-20));
            p->setPen(sub); p->setFont(QFont(o.font.family(),9)); p->drawText(QRect(r.left()+9,r.top()+148,r.width()-18,34),Qt::AlignHCenter|Qt::AlignTop|Qt::TextWordWrap,i.data(SizeRole).toString());
            if(o.state & QStyle::State_MouseOver) {const int half=(r.width()-20)/2;QRect revealRect(r.left()+8,r.bottom()-27,half,22),removeRect(revealRect.right()+4,r.bottom()-27,half,22);p->setPen(Qt::NoPen);p->setBrush(palette.color(QPalette::AlternateBase));p->drawRoundedRect(revealRect,7,7);p->drawRoundedRect(removeRect,7,7);p->setPen(accent);p->setFont(QFont(o.font.family(),9,QFont::DemiBold));p->drawText(revealRect,Qt::AlignCenter,QObject::tr("Reveal"));p->setPen(QColor("#FF453A"));p->drawText(removeRect,Qt::AlignCenter,QObject::tr("Remove"));}
        }
        p->restore();
    }
    bool editorEvent(QEvent *event, QAbstractItemModel *, const QStyleOptionViewItem &o, const QModelIndex &i) override
    {
        if(!o.widget || o.widget->property("statusMode").toBool() || event->type()!=QEvent::MouseButtonRelease) return false;
        const auto *mouse=static_cast<QMouseEvent *>(event); QRect r=o.rect.adjusted(4,4,-4,-4);const int half=(r.width()-20)/2;QRect revealRect(r.left()+8,r.bottom()-27,half,22),removeRect(revealRect.right()+4,r.bottom()-27,half,22);
        if(revealRect.contains(mouse->position().toPoint())&&reveal){reveal(i.data(PathRole).toString());return true;}if(removeRect.contains(mouse->position().toPoint()) && remove) { remove(i.data(TypeRole).toString()=="IMG"?0:i.data(TypeRole).toString()=="GIF"?1:2,i.data(RowRole).toInt()); return true; }
        return false;
    }
};

class FlowLayout final : public QLayout
{
public:
    explicit FlowLayout(QWidget *parent=nullptr) : QLayout(parent) { setSpacing(6); }
    ~FlowLayout() override { while(QLayoutItem *item=takeAt(0))delete item; }
    void addItem(QLayoutItem *item) override { items.append(item); }
    void insertWidget(int index,QWidget *widget){addChildWidget(widget);items.insert(qBound(0,index,items.size()),new QWidgetItem(widget));invalidate();}
    void addStretch(){addItem(new QSpacerItem(1,1,QSizePolicy::Expanding,QSizePolicy::Minimum));}
    int count() const override{return items.size();}
    QLayoutItem *itemAt(int index) const override{return items.value(index);}
    QLayoutItem *takeAt(int index) override{return index>=0&&index<items.size()?items.takeAt(index):nullptr;}
    Qt::Orientations expandingDirections() const override{return {};}
    bool hasHeightForWidth() const override{return true;}
    int heightForWidth(int width) const override{return layoutItems(QRect(0,0,width,0),true);}
    QSize sizeHint() const override{return minimumSize();}
    QSize minimumSize() const override{QSize size;for(QLayoutItem *item:items)size=size.expandedTo(item->minimumSize());const QMargins m=contentsMargins();return size+QSize(m.left()+m.right(),m.top()+m.bottom());}
    void setGeometry(const QRect &rect) override{QLayout::setGeometry(rect);layoutItems(rect,false);}
private:
    int layoutItems(const QRect &rect,bool test) const{const QMargins m=contentsMargins();const QRect area=rect.adjusted(m.left(),m.top(),-m.right(),-m.bottom());int x=area.x(),y=area.y(),lineHeight=0;for(QLayoutItem *item:items){const QSize hint=item->sizeHint();const int next=x+hint.width();if(next>area.right()+1&&lineHeight>0){x=area.x();y+=lineHeight+spacing();lineHeight=0;}if(!test)item->setGeometry(QRect(QPoint(x,y),hint));x+=hint.width()+spacing();lineHeight=qMax(lineHeight,hint.height());}return y+lineHeight-rect.y()+m.bottom();}
    QList<QLayoutItem*> items;
};

class AnimatedSegmentButton final : public QPushButton
{
    Q_OBJECT
    Q_PROPERTY(qreal pillProgress READ pillProgress WRITE setPillProgress)
public:
    explicit AnimatedSegmentButton(const QString &text,QWidget *parent) : QPushButton(text,parent) {}
    qreal pillProgress() const{return m_progress;}
    void setPillProgress(qreal value){m_progress=value;update();}
protected:
    void checkStateSet() override{QPushButton::checkStateSet();animateTo(isChecked());}
    void nextCheckState() override{QPushButton::nextCheckState();animateTo(isChecked());}
    void paintEvent(QPaintEvent *) override
    {
        QPainter painter(this);painter.setRenderHint(QPainter::Antialiasing);const QRectF frame=rect().adjusted(1,1,-1,-1);painter.setPen(Qt::NoPen);painter.setBrush(palette().color(QPalette::AlternateBase));painter.drawRoundedRect(frame,9,9);if(m_progress>0){painter.save();painter.setClipRect(QRectF(frame.left(),frame.top(),frame.width()*m_progress,frame.height()));QLinearGradient gradient(frame.topLeft(),frame.topRight());gradient.setColorAt(0,palette().color(QPalette::Highlight));gradient.setColorAt(1,QColor("#5E5CE6"));painter.setBrush(gradient);painter.drawRoundedRect(frame,9,9);painter.restore();}if(underMouse()||property("keyboardFocus").toBool()){painter.setPen(QPen(palette().color(QPalette::Highlight),property("keyboardFocus").toBool()?2:1));painter.setBrush(Qt::NoBrush);painter.drawRoundedRect(frame,9,9);}QStyleOptionButton option;initStyleOption(&option);QColor normal=palette().color(QPalette::Text),selected=Qt::white;auto mix=[this](int a,int b){return qRound(a+(b-a)*m_progress);};option.palette.setColor(QPalette::ButtonText,QColor(mix(normal.red(),selected.red()),mix(normal.green(),selected.green()),mix(normal.blue(),selected.blue())));style()->drawControl(QStyle::CE_PushButtonLabel,&option,&painter,this);
    }
private:
    void animateTo(bool checked){auto *animation=new QPropertyAnimation(this,"pillProgress",this);animation->setStartValue(m_progress);animation->setEndValue(checked?1.0:0.0);animation->setDuration(qEnvironmentVariableIsSet("W2X_SNAPSHOT_DIR")?0:160);animation->setEasingCurve(QEasingCurve::OutCubic);animation->start(QAbstractAnimation::DeleteWhenStopped);}
    qreal m_progress=0;
};

class ResponsiveGrid final : public QWidget
{
public:
    explicit ResponsiveGrid(QWidget *parent=nullptr) : QWidget(parent), grid(new QGridLayout(this)) { grid->setContentsMargins(0,0,0,0); grid->setSpacing(14); }
    void add(QWidget *w) { cards << w; relayout(); }
    void relayout() { while(grid->count()) grid->takeAt(0); const int cols=width()>=760?2:1; int visible=0; for(QWidget *card:cards) if(!card->isHidden()){ grid->addWidget(card,visible/cols,visible%cols); ++visible; } }
protected: void resizeEvent(QResizeEvent *e) override { QWidget::resizeEvent(e); relayout(); }
private:
    QGridLayout *grid; QList<QWidget*> cards;
};

class EngineGrid final : public QWidget
{
public:
    explicit EngineGrid(QWidget *parent=nullptr) : QWidget(parent), grid(new QGridLayout(this)) { grid->setContentsMargins(0,0,0,0); grid->setSpacing(12); }
    void add(QWidget *card) { card->setMinimumWidth(0);card->setSizePolicy(QSizePolicy::Ignored,QSizePolicy::Preferred);cards << card; relayout(); }
    void relayout() { while(grid->count()) grid->takeAt(0); const int cols=width()>=900?4:2; for(int i=0;i<cards.size();++i) grid->addWidget(cards[i],i/cols,i%cols);if(width()<400)return;for(QWidget *card:cards)card->setMinimumHeight(0);const int cardWidth=qMax(1,(width()-grid->horizontalSpacing()*(cols-1))/cols);int tallest=0;for(QWidget *card:cards){QLayout *layout=card->layout();int height=layout?layout->sizeHint().height():card->sizeHint().height();if(layout&&layout->hasHeightForWidth())height=qMax(height,layout->heightForWidth(cardWidth));tallest=qMax(tallest,height);}for(QWidget *card:cards)card->setMinimumHeight(tallest); }
protected: void resizeEvent(QResizeEvent *event) override { QWidget::resizeEvent(event); relayout(); }
private:
    QGridLayout *grid;
    QList<QWidget *> cards;
};

class KeyboardFocusFilter final : public QObject
{
public:
    using QObject::QObject;
protected:
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if(event->type()==QEvent::KeyPress){const int key=static_cast<QKeyEvent *>(event)->key();keyboardNavigation=key==Qt::Key_Tab||key==Qt::Key_Backtab;auto *button=qobject_cast<QAbstractButton *>(watched);if(button&&button->group()&&(key==Qt::Key_Left||key==Qt::Key_Right||key==Qt::Key_Up||key==Qt::Key_Down)&&(button->objectName()=="segment"||button->property("engineOrder").isValid())){QList<QAbstractButton *> buttons=button->group()->buttons();if(button->property("engineOrder").isValid())std::sort(buttons.begin(),buttons.end(),[](QAbstractButton *a,QAbstractButton *b){return a->property("engineOrder").toInt()<b->property("engineOrder").toInt();});const int columns=button->property("engineOrder").isValid()&&button->parentWidget()->width()<900?2:buttons.size();const int delta=key==Qt::Key_Left?-1:key==Qt::Key_Right?1:key==Qt::Key_Up?-columns:columns;const int index=buttons.indexOf(button),next=qBound(0,index+delta,buttons.size()-1);if(next!=index){keyboardNavigation=true;buttons[next]->click();buttons[next]->setFocus(Qt::OtherFocusReason);buttons[next]->setProperty("keyboardFocus",true);buttons[next]->style()->unpolish(buttons[next]);buttons[next]->style()->polish(buttons[next]);}return true;}}
        else if(event->type()==QEvent::MouseButtonPress)keyboardNavigation=false;
        auto *button=qobject_cast<QPushButton *>(watched); if(!button)return false;
        if(event->type()==QEvent::MouseButtonPress&&button->property("keyboardFocus").toBool()){button->setProperty("keyboardFocus",false);button->style()->unpolish(button);button->style()->polish(button);}
        else if(event->type()==QEvent::FocusIn){const auto reason=static_cast<QFocusEvent *>(event)->reason();button->setProperty("keyboardFocus",reason!=Qt::MouseFocusReason);keyboardNavigation=false;button->style()->unpolish(button);button->style()->polish(button);}
        else if(event->type()==QEvent::FocusOut){button->setProperty("keyboardFocus",false);button->style()->unpolish(button);button->style()->polish(button);}
        return false;
    }
private:
    bool keyboardNavigation=false;
};

QWidget *cardWidget(QWidget *parent, QVBoxLayout **layout = nullptr, bool = false)
{
    auto *card = new QWidget(parent); card->setObjectName("card");
    auto *box = new QVBoxLayout(card); box->setContentsMargins(20,20,20,20); box->setSpacing(10); if(layout) *layout=box; return card;
}

void addPageHeader(QVBoxLayout *layout, const QString &title, const QString &subtitle, int step = -1)
{
    static int nextStep=0;if(step<0)step=nextStep++%4;
    auto *band=new QWidget;band->setObjectName("headerBand");auto *box=new QVBoxLayout(band);box->setContentsMargins(0,0,0,8);box->setSpacing(8);auto *row=new QHBoxLayout;auto *text=new QVBoxLayout;text->setSpacing(2);auto *heading=new QLabel(title,band);heading->setObjectName("pageTitle");auto *sub=new QLabel(subtitle,band);sub->setObjectName("subtitle");sub->setWordWrap(true);sub->setSizePolicy(QSizePolicy::Ignored,QSizePolicy::Preferred);text->addWidget(heading);text->addWidget(sub);row->addLayout(text,1);auto *chip=new QLabel(band);chip->setObjectName("headerChip");chip->setProperty("stepHeaderChip",step);chip->setAlignment(Qt::AlignCenter);row->addWidget(chip,0,Qt::AlignTop);box->addLayout(row);auto *line=new QFrame(band);line->setObjectName("headerHairline");box->addWidget(line);layout->addWidget(band);
}

QPushButton *segmentButton(const QString &text, QWidget *parent)
{
    auto *button=new AnimatedSegmentButton(text,parent); button->setObjectName("segment"); button->setCheckable(true); button->setFocusPolicy(Qt::StrongFocus); button->setAccessibleName(text); return button;
}

void animateMetric(QLabel *label,qint64 target,const std::function<QString(qint64)> &format)
{
    label->setText(format(target));if(label->property("metricTarget").toLongLong()==target&&label->property("metricTarget").isValid())return;const qint64 start=label->property("metricValue").isValid()?label->property("metricValue").toLongLong():0;label->setProperty("metricTarget",target);auto *animation=new QVariantAnimation(label);animation->setStartValue(start);animation->setEndValue(target);animation->setDuration(qEnvironmentVariableIsSet("W2X_SNAPSHOT_DIR")?0:220);animation->setEasingCurve(QEasingCurve::OutCubic);QObject::connect(animation,&QVariantAnimation::valueChanged,label,[label,format](const QVariant &value){const qint64 number=value.toLongLong();label->setProperty("metricValue",number);label->setText(format(number));});animation->start(QAbstractAnimation::DeleteWhenStopped);
}

QString formattedResultSize(qint64 bytes)
{
    return bytes>=1024?QLocale().formattedDataSize(bytes):QObject::tr("%1 KB").arg(QLocale().toString(bytes/1024.0,'f',1));
}

class ComboPopupDelegate final : public QStyledItemDelegate
{
public: using QStyledItemDelegate::QStyledItemDelegate;
    void paint(QPainter *painter,const QStyleOptionViewItem &option,const QModelIndex &index) const override
    {
        QStyleOptionViewItem styled(option);initStyleOption(&styled,index);if(styled.state&QStyle::State_Selected){const Theme theme=wizardTheme();painter->fillRect(styled.rect,QColor(theme.accentTint));styled.state&=~QStyle::State_Selected;styled.backgroundBrush=Qt::NoBrush;styled.palette.setColor(QPalette::Text,QColor(theme.accent));styled.palette.setColor(QPalette::WindowText,QColor(theme.accent));}QStyledItemDelegate::paint(painter,styled,index);
    }
};

void fitComboPopup(QComboBox *combo)
{
    int width=160;const QFontMetrics metrics(combo->font());for(int i=0;i<combo->count();++i)width=qMax(width,metrics.horizontalAdvance(combo->itemText(i))+40);combo->setMinimumWidth(160);combo->view()->setMinimumWidth(width);if(!dynamic_cast<ComboPopupDelegate *>(combo->view()->itemDelegate()))combo->view()->setItemDelegate(new ComboPopupDelegate(combo->view()));const Theme theme=wizardTheme();QPalette palette=combo->view()->palette();palette.setColor(QPalette::Base,QColor(theme.card));palette.setColor(QPalette::Text,QColor(theme.text));palette.setColor(QPalette::Highlight,QColor(theme.accentTint));palette.setColor(QPalette::HighlightedText,QColor(theme.accent));combo->view()->setPalette(palette);
}

QComboBox *mirrorCombo(QComboBox *source, QWidget *parent)
{
    auto *combo=new QComboBox(parent); for(int i=0;i<source->count();++i) combo->addItem(source->itemText(i),source->itemData(i)); combo->setCurrentIndex(source->currentIndex());
    QObject::connect(combo,qOverload<int>(&QComboBox::currentIndexChanged),source,&QComboBox::setCurrentIndex);
    QObject::connect(source,qOverload<int>(&QComboBox::currentIndexChanged),combo,[combo](int i){ QSignalBlocker b(combo); combo->setCurrentIndex(i); }); fitComboPopup(combo);return combo;
}

void refreshRecent(QWidget *area, bool hasFiles)
{
    if(!area)return;const QByteArray json=QSettings().value("history/items").toByteArray();const QJsonArray items=QJsonDocument::fromJson(json).array();area->setVisible(!hasFiles&&!items.isEmpty());auto *host=area->findChild<QWidget*>("recentItems");if(!host||host->property("historyJson").toByteArray()==json)return;host->setProperty("historyJson",json);auto *row=qobject_cast<QHBoxLayout*>(host->layout());while(QLayoutItem *item=row->takeAt(0)){if(item->widget())item->widget()->deleteLater();delete item;}for(int i=0;i<qMin(6,items.size());++i){const QJsonObject value=items.at(i).toObject();const QString output=value.value("output").toString();auto *button=new QPushButton(host);button->setObjectName("recentTile");button->setAccessibleName(QObject::tr("Reveal recent output %1").arg(value.value("name").toString()));auto *box=new QHBoxLayout(button);box->setContentsMargins(8,8,8,8);auto *thumb=new QLabel(button);thumb->setFixedSize(52,52);thumb->setAlignment(Qt::AlignCenter);QPixmap pix(value.value("thumb").toString());if(pix.isNull())pix.load(output);if(!pix.isNull())thumb->setPixmap(pix.scaled(thumb->size(),Qt::KeepAspectRatio,Qt::SmoothTransformation));box->setSpacing(10);box->addWidget(thumb);auto *text=new QVBoxLayout;text->setSpacing(2);auto *name=new QLabel(value.value("name").toString(),button);name->setObjectName("typeTileTitle");name->setWordWrap(true);auto *meta=new QLabel(value.value("resolution").toString()+QStringLiteral("\n")+value.value("when").toString(),button);meta->setObjectName("caption");text->addWidget(name);text->addWidget(meta);box->addLayout(text,1);button->setCursor(Qt::PointingHandCursor);QObject::connect(button,&QPushButton::clicked,button,[output]{if(!output.isEmpty())QProcess::startDetached("/usr/bin/open",{"-R",output});});row->addWidget(button,1);}row->addStretch();
}

class WizardAdvancedDialog final : public QDialog
{
public:
    explicit WizardAdvancedDialog(QWidget *parent) : QDialog(parent)
    {
        setObjectName("wizardRoot"); setWindowTitle(tr("Advanced settings")); setModal(true); setMinimumSize(790,612);resize(790,612);
        auto *outer=new QVBoxLayout(this);outer->setContentsMargins(22,20,22,18);outer->setSpacing(12);
        auto *title=new QLabel(tr("Advanced settings"),this);title->setObjectName("pageTitle");outer->addWidget(title);
        auto *subtitle=new QLabel(tr("Fine-tune quality, speed and output. Defaults work well for most files."),this);subtitle->setObjectName("subtitle");outer->addWidget(subtitle);
        auto *body=new QHBoxLayout;body->setSpacing(16);auto *rail=new QWidget(this);rail->setObjectName("advancedTabs");rail->setFixedWidth(190);railLayout=new QVBoxLayout(rail);railLayout->setContentsMargins(8,8,8,8);railLayout->setSpacing(4);tabs=new QButtonGroup(this);tabs->setExclusive(true);body->addWidget(rail);
        pages=new QStackedWidget(this);body->addWidget(pages,1);outer->addLayout(body,1);
        auto *line=new QFrame(this);line->setObjectName("advancedFooterLine");outer->addWidget(line);auto *footer=new QHBoxLayout;restore=new QPushButton(tr("Restore defaults"),this);auto *done=new QPushButton(tr("Done"),this);done->setObjectName("primary");footer->addWidget(restore);footer->addStretch();footer->addWidget(done);outer->addLayout(footer);
        connect(tabs,&QButtonGroup::idClicked,pages,&QStackedWidget::setCurrentIndex);connect(done,&QPushButton::clicked,this,&QDialog::accept);
    }
    QVBoxLayout *addPage(const QString &label,const QString &icon)
    {
        QString buttonLabel=label;buttonLabel.replace("&","&&");auto *button=new QPushButton(buttonLabel,this);button->setObjectName("advancedTab");button->setCheckable(true);button->setFocusPolicy(Qt::StrongFocus);button->setAccessibleName(label);button->setAccessibleDescription(tr("Show the %1 advanced settings page").arg(label));button->setProperty("iconPath",icon);tabs->addButton(button,pages->count());railLayout->addWidget(button);auto *scroll=new QScrollArea(this);scroll->setWidgetResizable(true);auto *page=new QWidget(scroll);page->setObjectName("advancedPage");auto *layout=new QVBoxLayout(page);layout->setContentsMargins(4,4,10,4);layout->setSpacing(10);layout->addStretch();scroll->setWidget(page);pages->addWidget(scroll);return layout;
    }
    void setPage(int page){const QColor tint=wizardTheme().dark?QColor("#A9D3FF"):palette().color(QPalette::Highlight);for(QAbstractButton *entry:tabs->buttons())entry->setIcon(QIcon(svgPixmap(entry->property("iconPath").toString(),tint,QSize(20,20))));const int index=qBound(0,page,pages->count()-1);if(QAbstractButton *entry=tabs->button(index))entry->setChecked(true);pages->setCurrentIndex(index);}
    QButtonGroup *tabs;
    QVBoxLayout *railLayout;
    QStackedWidget *pages;
    QPushButton *restore;
};

}

qint64 MainWindow::Wizard_EstimateBytes(int type,qint64 inputBytes,qint64 inputPixels,qint64 outputPixels,double durationSeconds,qint64 audioBytes,int crf,bool hevc,double measuredRatio)
{
    if(inputBytes<=0||outputPixels<=0)return 0;
    const double outputMegapixels=outputPixels/1000000.0;
    if(measuredRatio>0)return qRound64(inputBytes*measuredRatio*outputMegapixels);
    if(type!=2){if(inputPixels<=0)return 0;const double areaRatio=double(outputPixels)/inputPixels;return qRound64(inputBytes*std::min(areaRatio,std::pow(areaRatio,0.85)));}
    if(durationSeconds<=0)return 0;
    const QList<QPair<int,double>> table={{14,1.70},{18,1.00},{23,0.55},{28,0.32}};double quality=table.first().second;if(crf>=table.last().first)quality=table.last().second;else for(int i=1;i<table.size();++i)if(crf<=table[i].first){const double t=double(crf-table[i-1].first)/(table[i].first-table[i-1].first);quality=table[i-1].second+t*(table[i].second-table[i-1].second);break;}
    const double videoBits=durationSeconds*3000000.0*outputMegapixels*quality*(hevc?0.6:1.0);
    return qRound64(videoBits/8.0)+qMax<qint64>(0,audioBytes);
}

QString MainWindow::Wizard_FormatMediaCaption(int type,const QSize &size,double durationSeconds,qint64 frameCount)
{
    if(!size.isValid())return tr("Reading media…");
    QStringList parts={tr("%1 × %2").arg(size.width()).arg(size.height())};
    if(type==2&&durationSeconds>=0){const qint64 seconds=qint64(durationSeconds),hours=seconds/3600,minutes=(seconds%3600)/60;parts<<(hours?QString("%1:%2:%3").arg(hours).arg(minutes,2,10,QChar('0')).arg(seconds%60,2,10,QChar('0')):QString("%1:%2").arg(minutes).arg(seconds%60,2,10,QChar('0')));}
    if(type>0&&frameCount>0)parts<<(frameCount==1?tr("1 frame"):tr("%1 frames").arg(frameCount));
    return parts.join(QStringLiteral(" · "));
}

void MainWindow::BuildWizard()
{
    QElapsedTimer buildTimer;
    const bool measure = qEnvironmentVariableIsSet("W2X_PERF");
    if(measure) buildTimer.start();
    setWindowTitle(tr("Waifu2x-Mac"));setMinimumSize(980,680);wizardNameTemplate=QSettings().value("wizard/nameTemplate",wizardNameTemplate).toString();const QRect available=QGuiApplication::primaryScreen()->availableGeometry();resize(QSize(1180,820).boundedTo(available.size()));const QByteArray savedGeometry=QSettings().value("geometry").toByteArray();if(!qEnvironmentVariableIsSet("W2X_SNAPSHOT_DIR")&&!savedGeometry.isEmpty())restoreGeometry(savedGeometry);resize(size().boundedTo(available.size()));move(qBound(available.left(),x(),available.right()-width()+1),qBound(available.top(),y(),available.bottom()-height()+1));
    wizardRoot=new QWidget(ui->centralwidget); wizardRoot->setObjectName("wizardRoot"); wizardRoot->setSizePolicy(QSizePolicy::Expanding,QSizePolicy::Ignored);
    wizardRefreshTimer=new QTimer(this);wizardRefreshTimer->setSingleShot(true);connect(wizardRefreshTimer,&QTimer::timeout,this,[this]{if(!wizardRefreshDirty)return;wizardRefreshDirty=false;Wizard_RefreshNow();});
    auto *rootLayout=new QHBoxLayout(wizardRoot); rootLayout->setContentsMargins(0,0,0,0); rootLayout->setSpacing(0);

    auto *sidebar=new SidebarPanel(wizardRoot); sidebar->setObjectName("sidebar"); sidebar->setFixedWidth(238);
    auto *side=new QVBoxLayout(sidebar); side->setContentsMargins(20,24,20,18); side->setSpacing(8);
    auto *brandRow=new QHBoxLayout; brandRow->setSpacing(10); brandRow->addWidget(new AppMark(sidebar));
    auto *brandText=new QVBoxLayout; brandText->setSpacing(0); auto *appName=new QLabel(tr("Waifu2x-Mac"),sidebar); appName->setObjectName("appName"); appName->setWordWrap(true); appName->setAccessibleName(tr("Waifu2x-Mac")); auto *tagline=new QLabel(tr("Make every pixel count"),sidebar); tagline->setObjectName("tagline"); brandText->addWidget(appName); brandText->addWidget(tagline); brandRow->addLayout(brandText,1); side->addLayout(brandRow); side->addSpacing(20);
    const QStringList names={tr("Add files"),tr("Upscaler"),tr("Options"),tr("Create")};
    const QStringList captions={tr("Photos, GIFs, video"),tr("Quality and size"),tr("Motion and output"),tr("Review and run")};
    for(int i=0;i<names.size();++i){ auto *b=new StepButton(i+1,names[i],captions[i],i==0,i==names.size()-1,sidebar); b->setAccessibleName(tr("Step %1: %2").arg(i+1).arg(names[i]));b->setAccessibleDescription(captions[i]);b->setFocusPolicy(Qt::StrongFocus); connect(b,&QPushButton::clicked,this,[this,i]{ if(!wizardRunning&&i<=wizardCurrentStep) Wizard_ShowStep(i); }); wizardStepButtons<<b; side->addWidget(b); }
    auto *session=new QWidget(sidebar);session->setObjectName("card");auto *sessionBox=new QVBoxLayout(session);sessionBox->setContentsMargins(14,12,14,12);sessionBox->setSpacing(6);auto *sessionTitle=new QLabel(tr("SESSION"),session);sessionTitle->setObjectName("sectionHeader");sessionBox->addWidget(sessionTitle);wizardSessionFiles=new QLabel(tr("No files yet"),session);wizardSessionFiles->setObjectName("caption");wizardSessionEngine=new QLabel(tr("Real-CUGAN · 2×"),session);wizardSessionEngine->setObjectName("typeTileTitle");sessionBox->addWidget(wizardSessionFiles);sessionBox->addWidget(wizardSessionEngine);wizardGpuPill=new QLabel(tr("Detecting this Mac…"),session);wizardGpuPill->setObjectName("gpuPill");wizardGpuPill->setAlignment(Qt::AlignCenter);sessionBox->addWidget(wizardGpuPill);side->addSpacing(8);side->addWidget(session);side->addStretch();
    auto *settings=new QPushButton(tr("  Settings"),sidebar); settings->setObjectName("sideSettings"); settings->setFocusPolicy(Qt::TabFocus); settings->setIcon(QIcon(svgPixmap(":/wizard/icons/wizard/settings.svg",QColor("#6E6E73"),QSize(18,18)))); settings->setAccessibleName(tr("Settings")); connect(settings,&QPushButton::clicked,this,&MainWindow::Wizard_ShowSettings); side->addWidget(settings);auto *version=new QLabel(tr("Waifu2x-Mac %1").arg(QStringLiteral(APP_VERSION)),sidebar);version->setObjectName("caption");version->setAlignment(Qt::AlignCenter);side->addWidget(version); rootLayout->addWidget(sidebar);
    auto *gpu=new QProcess(this); connect(gpu,qOverload<int,QProcess::ExitStatus>(&QProcess::finished),this,[this,gpu](int,QProcess::ExitStatus){ QString name=QString::fromUtf8(gpu->readAllStandardOutput()).trimmed(); if(name.isEmpty()) name=tr("this Mac"); wizardGpuPill->setText(tr("Running on %1").arg(name)); gpu->deleteLater(); }); gpu->start("/usr/sbin/sysctl",{"-n","machdep.cpu.brand_string"});

    auto *right=new QWidget(wizardRoot); auto *rightLayout=new QVBoxLayout(right); rightLayout->setContentsMargins(28,24,28,18); rightLayout->setSpacing(12);
    wizardStack=new QStackedWidget(right); qobject_cast<QStackedLayout *>(wizardStack->layout())->setStackingMode(QStackedLayout::StackOne); wizardStack->setSizePolicy(QSizePolicy::Expanding,QSizePolicy::Ignored); rightLayout->addWidget(wizardStack,1);

    wizardFilesPage=new QWidget(wizardStack); auto *filesPage=new QVBoxLayout(wizardFilesPage); filesPage->setContentsMargins(0,0,0,0); filesPage->setSpacing(14); addPageHeader(filesPage,tr("Add files"),tr("Choose the photos, animations, and videos you want to upscale."));
    wizardDropCard=new QWidget(wizardFilesPage); wizardDropCard->setObjectName("dropCard"); auto *drop=new QVBoxLayout(wizardDropCard); drop->setContentsMargins(24,30,24,30); drop->setSpacing(9); drop->addStretch(); drop->addWidget(new IconTile(":/wizard/icons/wizard/upload.svg",64,wizardDropCard),0,Qt::AlignHCenter);
    wizardDropTitle=new QLabel(tr("Drop files here"),wizardDropCard); wizardDropTitle->setObjectName("cardTitle"); wizardDropTitle->setAlignment(Qt::AlignCenter); wizardDropSubtitle=new QLabel(tr("PNG, JPG, WebP, GIF, MP4, MOV and more"),wizardDropCard); wizardDropSubtitle->setObjectName("subtitle"); wizardDropSubtitle->setAlignment(Qt::AlignCenter);
    auto *browse=new QPushButton(tr("Browse…"),wizardDropCard); browse->setObjectName("primary"); browse->setMaximumWidth(150); browse->setAccessibleName(tr("Browse for files")); connect(browse,&QPushButton::clicked,this,&MainWindow::on_pushButton_BrowserFile_clicked); drop->addWidget(wizardDropTitle); drop->addWidget(wizardDropSubtitle); drop->addWidget(browse,0,Qt::AlignHCenter); drop->addStretch(); filesPage->addWidget(wizardDropCard,1);

    drop->itemAt(1)->widget()->hide();drop->insertWidget(1,new HeroArt(wizardDropCard),0,Qt::AlignHCenter);wizardDropTitle->setText(tr("Drop to upscale"));wizardDropSubtitle->setText(tr("Photos, animations, and videos — processed privately on this Mac"));browse->setText(tr("Browse files…"));drop->removeWidget(browse);auto typeTile=[this](const QString &icon,const QString &title,const QString &formats){auto *tile=new QWidget(wizardDropCard);tile->setObjectName("typeTile");tile->setFixedSize(204,60);auto *row=new QHBoxLayout(tile);row->setContentsMargins(14,8,14,8);row->setSpacing(12);row->addStretch();auto *image=new QLabel(tile);image->setFixedSize(26,26);image->setAlignment(Qt::AlignCenter);image->setPixmap(svgPixmap(icon,QColor("#0A84FF"),QSize(24,24)));row->addWidget(image);auto *text=new QVBoxLayout;text->setSpacing(0);auto *name=new QLabel(title,tile);name->setObjectName("typeTileTitle");auto *detail=new QLabel(formats,tile);detail->setObjectName("caption");name->setAlignment(Qt::AlignLeft|Qt::AlignVCenter);detail->setAlignment(Qt::AlignLeft|Qt::AlignVCenter);text->addWidget(name);text->addWidget(detail);row->addLayout(text);row->addStretch();return tile;};auto *typesRow=new QHBoxLayout;typesRow->setSpacing(14);typesRow->addStretch();typesRow->addWidget(typeTile(":/wizard/icons/wizard/camera.svg",tr("Photos"),tr("PNG · JPG · WebP")));typesRow->addWidget(typeTile(":/wizard/icons/wizard/gif.svg",tr("GIFs"),tr("GIF · APNG")));typesRow->addWidget(typeTile(":/wizard/icons/wizard/film.svg",tr("Videos"),tr("MP4 · MOV · MKV")));typesRow->addStretch();drop->insertLayout(4,typesRow);auto *heroButtons=new QHBoxLayout;heroButtons->setSpacing(14);heroButtons->addStretch();browse->setFixedSize(168,44);heroButtons->addWidget(browse);auto *folderButton=new QPushButton(tr("Add folder…"),wizardDropCard);folderButton->setIcon(QIcon(svgPixmap(":/wizard/icons/wizard/folder.svg",QColor("#0A84FF"),QSize(18,18))));folderButton->setFixedSize(168,44);heroButtons->addWidget(folderButton);heroButtons->addStretch();drop->insertLayout(5,heroButtons);connect(folderButton,&QPushButton::clicked,this,[this]{const QString folder=QFileDialog::getExistingDirectory(this,tr("Add folder"));if(folder.isEmpty())return;AddNew_gif=AddNew_image=AddNew_video=false;QtConcurrent::run(&MainWindow::Read_urls,this,QList<QUrl>{QUrl::fromLocalFile(folder)});});
    wizardRecentArea=cardWidget(wizardFilesPage);auto *recentBox=qobject_cast<QVBoxLayout*>(wizardRecentArea->layout());auto *recentHead=new QHBoxLayout;auto *recentTitle=new QLabel(tr("Recent"),wizardRecentArea);recentTitle->setObjectName("cardTitle");recentHead->addWidget(recentTitle);recentHead->addStretch();auto *clearRecent=new QPushButton(tr("Clear"),wizardRecentArea);clearRecent->setObjectName("textButton");recentHead->addWidget(clearRecent);recentBox->addLayout(recentHead);auto *recentItems=new QWidget(wizardRecentArea);recentItems->setObjectName("recentItems");auto *recentRow=new QHBoxLayout(recentItems);recentRow->setContentsMargins(0,0,0,0);recentRow->setSpacing(8);recentBox->addWidget(recentItems);connect(clearRecent,&QPushButton::clicked,this,[this]{QSettings().remove("history/items");Wizard_Refresh();});filesPage->addWidget(wizardRecentArea);
    wizardFilesArea=cardWidget(wizardFilesPage,nullptr,true); auto *files=qobject_cast<QVBoxLayout*>(wizardFilesArea->layout()); auto *segments=new QHBoxLayout; auto *fileGroup=new QButtonGroup(this); fileGroup->setExclusive(true); const QStringList types={tr("Images"),tr("GIFs"),tr("Videos")};
    for(int i=0;i<types.size();++i){ auto *b=segmentButton(types[i],wizardFilesArea); b->setProperty("step1Control",true); fileGroup->addButton(b,i); wizardFileButtons<<b; segments->addWidget(b); } segments->addStretch(); auto *clear=new QPushButton(tr("Clear all"),wizardFilesArea); clear->setProperty("step1Control",true); connect(clear,&QPushButton::clicked,this,&MainWindow::on_pushButton_ClearList_clicked); segments->addWidget(clear); files->addLayout(segments);
    wizardFileGrid=new QListWidget(wizardFilesArea); wizardFileGrid->setViewMode(QListView::IconMode); wizardFileGrid->setResizeMode(QListView::Adjust); wizardFileGrid->setMovement(QListView::Static); wizardFileGrid->setSpacing(4); wizardFileGrid->setMouseTracking(true); wizardFileGrid->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff); wizardFileGrid->setSelectionMode(QAbstractItemView::SingleSelection); wizardFileGrid->setMinimumHeight(260);
    auto *delegate=new FileDelegate(wizardFileGrid); delegate->remove=[this](int type,int row){ curRow_image=type==0?row:-1; curRow_gif=type==1?row:-1; curRow_video=type==2?row:-1; on_pushButton_RemoveItem_clicked(); Wizard_Refresh(); };delegate->reveal=[](const QString &path){if(!path.isEmpty())QProcess::startDetached("/usr/bin/open",{"-R",path});};wizardFileGrid->setItemDelegate(delegate);files->addWidget(wizardFileGrid,1);auto *fileFooter=new QWidget(wizardFilesArea);fileFooter->setObjectName("fileFooter");auto *fileFooterLayout=new QHBoxLayout(fileFooter);fileFooterLayout->setContentsMargins(12,8,12,8);wizardFilesFooter=new QLabel(fileFooter);wizardFilesFooter->setObjectName("caption");fileFooterLayout->addWidget(wizardFilesFooter);fileFooterLayout->addStretch();files->addWidget(fileFooter);
    for(QTableView *table:{ui->tableView_image,ui->tableView_gif,ui->tableView_video}){ table->setParent(wizardFilesArea); table->hide(); }
    connect(fileGroup,&QButtonGroup::idClicked,this,[this](int id){ wizardRoot->setProperty("fileFilter",id); Wizard_Refresh(); }); filesPage->addWidget(wizardFilesArea,1); wizardStack->addWidget(wizardFilesPage);

    auto *qualityPage=new QWidget(wizardStack); auto *quality=new QVBoxLayout(qualityPage); quality->setContentsMargins(0,0,0,0); quality->setSpacing(8); addPageHeader(quality,tr("Choose upscaler"),tr("Pick the best balance of speed, detail, and output size."));wizardPresetRow=new QWidget(qualityPage);auto *presetChips=new FlowLayout(wizardPresetRow);presetChips->setContentsMargins(0,0,0,0);presetChips->setSpacing(4);presetChips->addWidget(new QLabel(tr("Presets"),wizardPresetRow));for(const QString &name:{tr("Anime wallpaper 4K"),tr("Photo restore"),tr("Quick preview"),tr("Smooth GIF")}){auto *button=segmentButton(name,wizardPresetRow);button->setProperty("presetName",name);connect(button,&QPushButton::clicked,this,[this,name]{Wizard_ApplyPreset(name);});presetChips->addWidget(button);}QSettings presetSettings;presetSettings.beginGroup("presets");const QStringList presetKeys=presetSettings.childKeys();for(const QString &key:presetKeys){const QJsonDocument document=QJsonDocument::fromJson(presetSettings.value(key).toByteArray());if(!document.isObject())continue;const QJsonObject state=document.object();const QString name=state.value("presetName").toString();if(name.isEmpty())continue;auto *button=segmentButton(name,wizardPresetRow);button->setProperty("presetKey",key);button->setProperty("presetJson",QString::fromUtf8(document.toJson(QJsonDocument::Compact)));button->setContextMenuPolicy(Qt::CustomContextMenu);connect(button,&QPushButton::clicked,this,[this,state]{Wizard_ApplyState(state);});connect(button,&QPushButton::customContextMenuRequested,this,[button,key](const QPoint &position){QMenu menu;QAction *remove=menu.addAction(tr("Delete preset"));if(menu.exec(button->mapToGlobal(position))==remove){QSettings settings;settings.remove("presets/"+key);button->deleteLater();}});presetChips->addWidget(button);}presetSettings.endGroup();auto *savePreset=new QPushButton(tr("Save preset…"),wizardPresetRow);savePreset->setAccessibleName(tr("Save current as preset…"));savePreset->setToolTip(tr("Save current as preset…"));connect(savePreset,&QPushButton::clicked,this,[this,presetChips]{bool ok=false;const QString name=QInputDialog::getText(this,tr("Save preset"),tr("Preset name"),QLineEdit::Normal,QString(),&ok).trimmed();if(!ok||name.isEmpty())return;QJsonObject state=Wizard_State();state["presetName"]=name;const QString key=QString::fromLatin1(name.toUtf8().toBase64(QByteArray::Base64UrlEncoding|QByteArray::OmitTrailingEquals));const QByteArray json=QJsonDocument(state).toJson(QJsonDocument::Compact);QSettings().setValue("presets/"+key,json);auto *button=segmentButton(name,wizardPresetRow);button->setProperty("presetKey",key);button->setProperty("presetJson",QString::fromUtf8(json));button->setContextMenuPolicy(Qt::CustomContextMenu);connect(button,&QPushButton::clicked,this,[this,state]{Wizard_ApplyState(state);});connect(button,&QPushButton::customContextMenuRequested,this,[button,key](const QPoint &position){QMenu menu;QAction *remove=menu.addAction(tr("Delete preset"));if(menu.exec(button->mapToGlobal(position))==remove){QSettings().remove("presets/"+key);button->deleteLater();}});presetChips->insertWidget(presetChips->count()-1,button);Wizard_Refresh();});presetChips->addWidget(savePreset);presetChips->addStretch();quality->addWidget(wizardPresetRow);auto *engines=new EngineGrid(qualityPage); auto *engineGroup=new QButtonGroup(this); engineGroup->setExclusive(true);
    QVBoxLayout *liveBox;auto *livePreview=cardWidget(qualityPage,&liveBox);livePreview->setObjectName("card");livePreview->setMinimumWidth(0);livePreview->setSizePolicy(QSizePolicy::Ignored,QSizePolicy::Preferred);auto *liveHead=new QHBoxLayout;auto *compareIcon=new QLabel(livePreview);compareIcon->setPixmap(svgPixmap(":/wizard/icons/wizard/compare.svg",QColor("#0A84FF"),QSize(22,22)));liveHead->addWidget(compareIcon);auto *liveTitle=new QLabel(tr("Compare"),livePreview);liveTitle->setObjectName("cardTitle");liveHead->addWidget(liveTitle);liveHead->addStretch();liveBox->addLayout(liveHead);auto *liveControls=new QHBoxLayout;liveControls->addStretch();auto *zoom1=segmentButton(tr("1×"),livePreview);auto *zoom2=segmentButton(tr("2×"),livePreview);zoom1->setChecked(true);auto *zoomGroup=new QButtonGroup(this);zoomGroup->addButton(zoom1,1);zoomGroup->addButton(zoom2,2);liveControls->addWidget(zoom1);liveControls->addWidget(zoom2);wizardGeneratePreview=new QPushButton(tr("Generate preview"),livePreview);wizardGeneratePreview->setIcon(QIcon(svgPixmap(":/wizard/icons/wizard/sparkles.svg",QColor("#0A84FF"),QSize(18,18))));liveControls->addWidget(wizardGeneratePreview);liveBox->addLayout(liveControls);wizardCompare=new CompareSlider(livePreview);liveBox->addWidget(wizardCompare);wizardPreviewStatus=new QLabel(tr("Uses a small center crop from your first file."),livePreview);wizardPreviewStatus->setObjectName("helper");wizardPreviewStatus->setWordWrap(true);wizardPreviewStatus->setSizePolicy(QSizePolicy::Ignored,QSizePolicy::Preferred);liveBox->addWidget(wizardPreviewStatus);wizardPreviewTimer=new QTimer(this);wizardPreviewTimer->setSingleShot(true);connect(wizardPreviewTimer,&QTimer::timeout,this,&MainWindow::Wizard_RunPreview);connect(wizardGeneratePreview,&QPushButton::clicked,this,[this]{Wizard_RequestPreview(true);});connect(zoomGroup,&QButtonGroup::idClicked,wizardCompare,&CompareSlider::setZoom);connect(qApp,&QCoreApplication::aboutToQuit,this,[this]{Wizard_CancelPreview();QDir(Data_Path+"/Preview").removeRecursively();});
    liveBox->removeItem(liveControls);liveControls->setParent(nullptr);liveHead->addLayout(liveControls);
    const QList<int> engineIds={7,8,9,10}; const QStringList engineTitles={tr("Fast"),tr("Best for anime"),tr("Sharp"),tr("Photos")}; const QStringList engineNames={tr("MetalFX"),tr("Real-CUGAN"),tr("Real-ESRGAN"),tr("Real-ESRGAN / RealSR")}; const QStringList engineIcons={":/wizard/icons/wizard/bolt.svg",":/wizard/icons/wizard/sparkles.svg",":/wizard/icons/wizard/sharp.svg",":/wizard/icons/wizard/camera.svg"}; const QStringList engineDescriptions={tr("Apple GPU scaling for quick, clean results."),tr("Smooth line art and remove compression noise."),tr("Bring out crisp texture in illustrations and photos."),tr("Natural detail for real people, landscapes and everyday photos")};
    for(int i=0;i<4;++i){ auto *b=new QPushButton(qualityPage); b->setObjectName(i==3?"photosCard":"engineCard"); if(i==3)b->setProperty("photoCard",true); b->setCheckable(true); b->setProperty("engineId",i==3?9:engineIds[i]);b->setProperty("engineOrder",i);b->setProperty("engineTitle",engineTitles[i]); auto *box=new QVBoxLayout(b); box->setContentsMargins(14,13,14,13); box->setSpacing(7); auto *top=new QHBoxLayout; top->addWidget(new IconTile(engineIcons[i],40,b)); top->addStretch(); auto *check=new QLabel(QString::fromUtf8("✓"),b); check->setObjectName("engineCheck"); check->setFixedSize(18,18); check->setAlignment(Qt::AlignCenter); top->addWidget(check); box->addLayout(top); auto *title=new QLabel(engineTitles[i],b); title->setObjectName("engineTitle"); box->addWidget(title); auto *pillRow=new QHBoxLayout; auto *pill=new QLabel(engineNames[i],b); pill->setObjectName("pill"); pill->setWordWrap(true); pill->setSizePolicy(QSizePolicy::Preferred,QSizePolicy::Minimum); pillRow->addWidget(pill); pillRow->addStretch(); box->addLayout(pillRow); if(i==1||i==3){ auto *recommended=new QLabel(i==3?tr("Photos pick"):tr("Recommended"),b); recommended->setObjectName("recommendedPill"); recommended->setWordWrap(true); recommended->setSizePolicy(QSizePolicy::Preferred,QSizePolicy::Minimum); box->addWidget(recommended,0,Qt::AlignLeft); } auto *description=new QLabel(engineDescriptions[i],b); description->setObjectName("engineDescription"); description->setWordWrap(true); description->setMinimumHeight(description->fontMetrics().lineSpacing()*3); description->setSizePolicy(QSizePolicy::Preferred,QSizePolicy::Minimum); box->addWidget(description); for(QLabel *label:b->findChildren<QLabel*>()) label->setAttribute(Qt::WA_TransparentForMouseEvents); engineGroup->addButton(b,engineIds[i]); engines->add(b); }
    const QStringList bestFor={tr("Best for: quick drafts"),tr("Best for: anime and line art"),tr("Best for: crisp texture"),tr("Best for: portraits and photos")};const QStringList meters={tr("Speed  ●●●●●   Detail  ●●○○○"),tr("Speed  ●●●○○   Detail  ●●●●○"),tr("Speed  ●●○○○   Detail  ●●●●●"),tr("Speed  ●●○○○   Detail  ●●●●●")};for(QAbstractButton *abstract:engineGroup->buttons()){auto *button=qobject_cast<QPushButton*>(abstract);const int i=button->property("engineOrder").toInt();auto *box=qobject_cast<QVBoxLayout*>(button->layout());auto *best=new QLabel(bestFor.value(i),button);best->setObjectName("helper");best->setWordWrap(true);auto *meter=new QLabel(meters.value(i),button);meter->setObjectName("caption");meter->setWordWrap(true);box->addWidget(best);box->addWidget(meter);for(QLabel *label:button->findChildren<QLabel*>())label->setAttribute(Qt::WA_TransparentForMouseEvents);}engines->relayout();for(QPushButton *preset:wizardPresetRow->findChildren<QPushButton*>())preset->setIcon(QIcon(svgPixmap(":/wizard/icons/wizard/sparkles.svg",QColor("#0A84FF"),QSize(15,15))));quality->addWidget(engines);
    QVBoxLayout *sizeBox;auto *sizeCard=cardWidget(qualityPage,&sizeBox);auto *sizeHead=new QHBoxLayout;auto *sizeTitle=new QLabel(tr("Output size"),sizeCard);sizeTitle->setObjectName("cardTitle");sizeHead->addWidget(sizeTitle);sizeHead->addStretch();wizardTargetModeGroup=new QButtonGroup(this);for(int mode=0;mode<2;++mode){auto *button=segmentButton(mode?tr("Fit to…"):tr("Scale"),sizeCard);wizardTargetModeGroup->addButton(button,mode);sizeHead->addWidget(button);}sizeBox->addLayout(sizeHead);
    wizardScaleControls=new QWidget(sizeCard);auto *sizes=new QHBoxLayout(wizardScaleControls);sizes->setContentsMargins(0,0,0,0);wizardSizeGroup=new QButtonGroup(this);wizardSizeGroup->setExclusive(true);for(int factor:{2,3,4,8}){auto *button=segmentButton(tr("%1×").arg(factor),sizeCard);wizardSizeGroup->addButton(button,factor);sizes->addWidget(button);}wizardCustomScale=new QDoubleSpinBox(sizeCard);wizardCustomScale->setRange(ui->doubleSpinBox_ScaleRatio_image->minimum(),ui->doubleSpinBox_ScaleRatio_image->maximum());wizardCustomScale->setDecimals(1);wizardCustomScale->setPrefix(tr("Custom: "));wizardCustomScale->setFixedWidth(120);sizes->addWidget(wizardCustomScale);sizeBox->addWidget(wizardScaleControls);
    wizardTargetControls=new QWidget(sizeCard);auto *targetBox=new QVBoxLayout(wizardTargetControls);targetBox->setContentsMargins(0,0,0,0);auto *targetChips=new QHBoxLayout;wizardTargetPresetGroup=new QButtonGroup(this);const QStringList targetNames={tr("1080p"),tr("1440p"),tr("4K"),tr("8K"),tr("iPhone wallpaper")};for(int i=0;i<targetNames.size();++i){auto *button=segmentButton(targetNames[i],sizeCard);wizardTargetPresetGroup->addButton(button,i);targetChips->addWidget(button);}targetBox->addLayout(targetChips);auto *customTarget=new QHBoxLayout;customTarget->addWidget(new QLabel(tr("Custom"),sizeCard));wizardTargetWidth=new QSpinBox(sizeCard);wizardTargetHeight=new QSpinBox(sizeCard);for(QSpinBox *spin:{wizardTargetWidth,wizardTargetHeight})spin->setRange(64,16384);wizardTargetWidth->setValue(QSettings().value("wizard/targetWidth",3840).toInt());wizardTargetHeight->setValue(QSettings().value("wizard/targetHeight",2160).toInt());customTarget->addWidget(wizardTargetWidth);customTarget->addWidget(new QLabel(QString::fromUtf8("×"),sizeCard));customTarget->addWidget(wizardTargetHeight);auto *fitMode=new QComboBox(sizeCard);fitMode->addItem(tr("Fit inside (keep aspect)"));customTarget->addWidget(fitMode,1);targetBox->addLayout(customTarget);wizardTargetNote=new QLabel(tr("Files already larger than the target stay unchanged."),sizeCard);wizardTargetNote->setObjectName("helper");targetBox->addWidget(wizardTargetNote);sizeBox->addWidget(wizardTargetControls);wizardScaleCaption=new QLabel(sizeCard);wizardScaleCaption->setObjectName("caption");sizeBox->addWidget(wizardScaleCaption);wizardTargetEnabled=QSettings().value("wizard/targetEnabled",false).toBool();wizardTargetModeGroup->button(wizardTargetEnabled?1:0)->setChecked(true);wizardTargetControls->setVisible(wizardTargetEnabled);wizardScaleControls->setVisible(!wizardTargetEnabled);quality->addWidget(sizeCard);
    wizardNoiseRow=cardWidget(qualityPage); auto *noise=qobject_cast<QVBoxLayout*>(wizardNoiseRow->layout()); auto *noiseTitle=new QLabel(tr("Noise reduction"),wizardNoiseRow); noiseTitle->setObjectName("cardTitle"); noise->addWidget(noiseTitle); auto *noiseButtons=new QHBoxLayout; wizardNoiseGroup=new QButtonGroup(this); wizardNoiseGroup->setExclusive(true); const QStringList noiseNames={tr("Off"),tr("Low"),tr("Medium"),tr("High")}; for(int i=0;i<4;++i){ auto *b=segmentButton(noiseNames[i],wizardNoiseRow); wizardNoiseGroup->addButton(b,i); noiseButtons->addWidget(b); } noise->addLayout(noiseButtons); quality->addWidget(wizardNoiseRow);
    auto makeModel=[&](const QString &title,QComboBox *source,QWidget **member){ *member=cardWidget(qualityPage); auto *box=qobject_cast<QVBoxLayout*>((*member)->layout()); auto *label=new QLabel(title,*member); label->setObjectName("cardTitle"); box->addWidget(label); box->addWidget(mirrorCombo(source,*member));connect(source,qOverload<int>(&QComboBox::currentIndexChanged),this,[this](int){Wizard_Refresh();}); quality->addWidget(*member); }; makeModel(tr("Real-CUGAN model"),ui->comboBox_Model_RealCUGAN,&wizardCuganModelRow); makeModel(tr("Real-ESRGAN model"),ui->comboBox_Model_RealESRGAN,&wizardEsrganModelRow);
    wizardPhotoModelRow=cardWidget(qualityPage); auto *photoBox=qobject_cast<QVBoxLayout *>(wizardPhotoModelRow->layout()); auto *photoLabel=new QLabel(tr("Photo model"),wizardPhotoModelRow); photoLabel->setObjectName("cardTitle"); photoBox->addWidget(photoLabel); wizardPhotoModel=new QComboBox(wizardPhotoModelRow); photoBox->addWidget(wizardPhotoModel);
    const QStringList photoNames={tr("Photo - General (fast, realesr-general-x4v3)"),tr("Photo - LSDIR (natural detail)"),tr("Photo - UltraSharp (very crisp)"),tr("Photo - Siax (sharp, textured)")}; for(int i=0;i<4;++i)if(ui->comboBox_Model_RealESRGAN->findData(7+i)>=0)wizardPhotoModel->addItem(photoNames[i],900+7+i);
    if(QDir(Current_Path+"/realsr-ncnn-vulkan/models-DF2K_JPEG").exists())wizardPhotoModel->addItem(tr("RealSR (natural, removes JPEG noise)"),500);
    if(QDir(Current_Path+"/realsr-ncnn-vulkan/models-DF2K").exists())wizardPhotoModel->addItem(tr("RealSR (clean source)"),501);
    const int lsdirPhoto=wizardPhotoModel->findData(908); wizardPhotoModel->setCurrentIndex(lsdirPhoto>=0?lsdirPhoto:(wizardPhotoModel->count()?0:-1)); quality->addWidget(wizardPhotoModelRow);

    QVBoxLayout *previewBox; auto *preview=cardWidget(qualityPage,&previewBox); auto *previewTitle=new QLabel(tr("Preview"),preview); previewTitle->setObjectName("cardTitle"); previewBox->addWidget(previewTitle); auto *previewRow=new QHBoxLayout; wizardPreviewImage=new QLabel(preview); wizardPreviewImage->setFixedSize(72,58); wizardPreviewImage->setAlignment(Qt::AlignCenter); wizardPreviewImage->setObjectName("thumbnailPreview"); previewRow->addWidget(wizardPreviewImage); auto *previewText=new QVBoxLayout; wizardPreviewInput=new QLabel(tr("Add a file to preview dimensions"),preview); wizardPreviewInput->setObjectName("caption"); wizardPreviewOutput=new QLabel(preview); wizardPreviewOutput->setObjectName("cardTitle"); previewText->addWidget(wizardPreviewInput); previewText->addWidget(wizardPreviewOutput); previewRow->addLayout(previewText,1); previewBox->addLayout(previewRow); quality->addWidget(preview);quality->addWidget(livePreview); quality->addStretch(); auto *qualityScroll=new QScrollArea(wizardStack); qualityScroll->setWidgetResizable(true); qualityScroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);qualityScroll->setFrameShape(QFrame::NoFrame); qualityScroll->setWidget(qualityPage); wizardStack->addWidget(qualityScroll);
    auto setScale=[this](double f){ui->doubleSpinBox_ScaleRatio_image->setValue(f);ui->doubleSpinBox_ScaleRatio_gif->setValue(f);ui->doubleSpinBox_ScaleRatio_video->setValue(f);QSignalBlocker b(wizardCustomScale);wizardCustomScale->setValue(f);Wizard_Refresh();};connect(wizardSizeGroup,&QButtonGroup::idClicked,this,[setScale](int f){setScale(f);});connect(wizardCustomScale,qOverload<double>(&QDoubleSpinBox::valueChanged),this,[setScale](double f){setScale(f);});connect(wizardTargetModeGroup,&QButtonGroup::idClicked,this,[this](int mode){wizardTargetEnabled=mode==1;QSettings().setValue("wizard/targetEnabled",wizardTargetEnabled);wizardScaleControls->setVisible(!wizardTargetEnabled);wizardTargetControls->setVisible(wizardTargetEnabled);if(wizardTargetEnabled)Wizard_ApplyTargetSize();else if(Table_model_image->rowCount()+Table_model_gif->rowCount()+Table_model_video->rowCount()){ui->checkBox_custres_isAll->setChecked(true);on_pushButton_CustRes_cancel_clicked();}Wizard_Refresh();});
    const QList<QSize> targetSizes={{1920,1080},{2560,1440},{3840,2160},{7680,4320},{1290,2796}};connect(wizardTargetPresetGroup,&QButtonGroup::idClicked,this,[this,targetSizes](int id){wizardTargetWidth->setValue(targetSizes[id].width());wizardTargetHeight->setValue(targetSizes[id].height());Wizard_ApplyTargetSize();});auto targetChanged=[this]{QSettings().setValue("wizard/targetWidth",wizardTargetWidth->value());QSettings().setValue("wizard/targetHeight",wizardTargetHeight->value());Wizard_ApplyTargetSize();};connect(wizardTargetWidth,qOverload<int>(&QSpinBox::valueChanged),this,[targetChanged](int){targetChanged();});connect(wizardTargetHeight,qOverload<int>(&QSpinBox::valueChanged),this,[targetChanged](int){targetChanged();});connect(wizardNoiseGroup,&QButtonGroup::idClicked,this,[this](int n){ui->spinBox_DenoiseLevel_image->setValue(n);ui->spinBox_DenoiseLevel_gif->setValue(n);ui->spinBox_DenoiseLevel_video->setValue(n);Wizard_Refresh();}); connect(engineGroup,&QButtonGroup::idToggled,this,[this](int id,bool checked){if(!checked)return;const bool photo=id==10;if(photo){const int choice=wizardPhotoModel->currentData().toInt();id=choice>=500?choice/100:9;if(id==9)SetComboId(ui->comboBox_Model_RealESRGAN,choice%100);else if(id==5)ui->comboBox_Model_RealsrNCNNVulkan->setCurrentIndex(choice%100);}Wizard_SelectEngine(id,photo);});
    for(QAbstractButton *button:engineGroup->buttons())button->setFocusPolicy(Qt::StrongFocus);
    connect(wizardPhotoModel,qOverload<int>(&QComboBox::currentIndexChanged),this,[this](int){const int choice=wizardPhotoModel->currentData().toInt(),engine=choice/100,model=choice%100;if(engine==9)SetComboId(ui->comboBox_Model_RealESRGAN,model);else ui->comboBox_Model_RealsrNCNNVulkan->setCurrentIndex(model);Wizard_SelectEngine(engine,true);});
    auto *optionsPage=new QWidget(wizardStack); auto *optionsOuter=new QVBoxLayout(optionsPage); optionsOuter->setContentsMargins(0,0,0,0); addPageHeader(optionsOuter,tr("Options"),tr("Fine-tune motion, formats, and where your results go.")); auto *scroll=new QScrollArea(optionsPage); scroll->setWidgetResizable(true); scroll->setFrameShape(QFrame::NoFrame); auto *optionsContent=new QWidget(scroll); auto *optionsLayout=new QVBoxLayout(optionsContent); optionsLayout->setContentsMargins(0,0,0,0);QVBoxLayout *estimateBox;auto *estimate=cardWidget(optionsContent,&estimateBox);auto *estimateHead=new QHBoxLayout;auto *estimateTitle=new QLabel(tr("Estimate"),estimate);estimateTitle->setObjectName("cardTitle");estimateHead->addWidget(new IconTile(":/wizard/icons/wizard/clock.svg",34,estimate));estimateHead->addWidget(estimateTitle);estimateHead->addStretch();auto *gpuChip=new QLabel(tr("Apple GPU"),estimate);gpuChip->setObjectName("sessionChip");auto *fpChip=new QLabel(tr("FP16"),estimate);fpChip->setObjectName("sessionChip");estimateHead->addWidget(gpuChip);estimateHead->addWidget(fpChip);estimateBox->addLayout(estimateHead);auto *estimateGrid=new QGridLayout;estimateGrid->setContentsMargins(0,4,0,0);estimateGrid->setHorizontalSpacing(24);auto metric=[estimate,estimateGrid](int column,const QString &title,QLabel **value){*value=new QLabel(estimate);(*value)->setObjectName("estimateValue");auto *caption=new QLabel(title,estimate);caption->setObjectName("caption");estimateGrid->addWidget(*value,0,column);estimateGrid->addWidget(caption,1,column);estimateGrid->setColumnStretch(column,1);};metric(0,tr("OUTPUT RESOLUTION"),&wizardEstimateResolution);metric(1,tr("APPROXIMATE SIZE"),&wizardEstimateSize);metric(2,tr("ESTIMATED TIME"),&wizardEstimateTime);estimateBox->addLayout(estimateGrid);optionsLayout->addWidget(estimate);auto *grid=new ResponsiveGrid(optionsContent); grid->setObjectName("optionsGrid"); optionsLayout->addWidget(grid);
    auto optionCard=[&](const QString &icon,const QString &title,const QString &helper){ QVBoxLayout *box; auto *card=cardWidget(grid,&box); auto *head=new QHBoxLayout; head->addWidget(new IconTile(icon,34,card)); auto *labels=new QVBoxLayout; labels->setSpacing(1); auto *label=new QLabel(title,card); label->setObjectName("cardTitle"); auto *sub=new QLabel(helper,card); sub->setObjectName("helper"); sub->setWordWrap(true); labels->addWidget(label); labels->addWidget(sub); head->addLayout(labels,1); box->addLayout(head); grid->add(card); return qMakePair(card,box); };
    auto motion=optionCard(":/wizard/icons/wizard/motion.svg",tr("Smoother motion"),tr("Create extra frames for more fluid GIFs and videos.")); wizardMotionCard=motion.first; auto *motionSwitch=new ToggleSwitch(wizardMotionCard); motionSwitch->setAccessibleName(tr("Enable smoother motion")); motionSwitch->setChecked(ui->checkBox_EnableVFI_Home->isChecked()); motionSwitch->setOffset(motionSwitch->isChecked()); motion.second->itemAt(0)->layout()->addWidget(motionSwitch); auto *fps=new QHBoxLayout; auto *fpsGroup=new QButtonGroup(this); for(int factor:{2,3,4}){auto *b=segmentButton(tr("%1× frames").arg(factor),wizardMotionCard);fpsGroup->addButton(b,factor);fps->addWidget(b);} motion.second->addLayout(fps); connect(motionSwitch,&QAbstractButton::toggled,ui->checkBox_EnableVFI_Home,&QCheckBox::setChecked); connect(fpsGroup,&QButtonGroup::idClicked,ui->spinBox_MultipleOfFPS_VFI,&QSpinBox::setValue); SetComboId(ui->comboBox_Engine_VFI,0);
    auto image=optionCard(":/wizard/icons/wizard/image.svg",tr("Image format"),tr("Choose compression and quality for still images.")); wizardImageCard=image.first; auto *format=mirrorCombo(ui->comboBox_ImageSaveFormat,wizardImageCard); image.second->addWidget(format); auto *qualityRow=new QHBoxLayout; auto *qualitySlider=new QSlider(Qt::Horizontal,wizardImageCard); auto *qualitySpin=new QSpinBox(wizardImageCard); qualitySlider->setRange(ui->spinBox_ImageQualityLevel->minimum(),ui->spinBox_ImageQualityLevel->maximum()); qualitySpin->setRange(qualitySlider->minimum(),qualitySlider->maximum()); qualitySlider->setValue(ui->spinBox_ImageQualityLevel->value()); qualitySpin->setValue(qualitySlider->value()); qualityRow->addWidget(new QLabel(tr("Quality"),wizardImageCard)); qualityRow->addWidget(qualitySlider,1); qualityRow->addWidget(qualitySpin); image.second->addLayout(qualityRow); connect(qualitySlider,&QSlider::valueChanged,qualitySpin,&QSpinBox::setValue); connect(qualitySpin,qOverload<int>(&QSpinBox::valueChanged),qualitySlider,&QSlider::setValue); connect(qualitySpin,qOverload<int>(&QSpinBox::valueChanged),ui->spinBox_ImageQualityLevel,&QSpinBox::setValue);
    auto gif=optionCard(":/wizard/icons/wizard/gif.svg",tr("Smaller GIFs"),tr("Optimize animation size after upscaling.")); wizardGifCard=gif.first; auto *gifSwitch=new ToggleSwitch(wizardGifCard); gifSwitch->setAccessibleName(tr("Optimize GIF size")); gifSwitch->setChecked(ui->checkBox_OptGIF->isChecked()); gifSwitch->setOffset(gifSwitch->isChecked()); gif.second->itemAt(0)->layout()->addWidget(gifSwitch); connect(gifSwitch,&QAbstractButton::toggled,ui->checkBox_OptGIF,&QCheckBox::setChecked);
    auto save=optionCard(":/wizard/icons/wizard/folder.svg",tr("Save to"),tr("Keep results beside originals or choose one folder.")); auto *nextToOriginal=new QRadioButton(tr("Next to the original files"),save.first); auto *chooseFolder=new QRadioButton(tr("Choose a folder…"),save.first); nextToOriginal->setChecked(!ui->checkBox_OutPath_isEnabled->isChecked()); chooseFolder->setChecked(ui->checkBox_OutPath_isEnabled->isChecked()); wizardOutputPath=new QLabel(ui->lineEdit_outputPath->text(),save.first); wizardOutputPath->setObjectName("caption"); save.second->addWidget(nextToOriginal); save.second->addWidget(chooseFolder); save.second->addWidget(wizardOutputPath); connect(nextToOriginal,&QRadioButton::toggled,this,[this](bool on){if(on)ui->checkBox_OutPath_isEnabled->setChecked(false);}); connect(chooseFolder,&QRadioButton::clicked,this,[this,chooseFolder]{QString folder=QFileDialog::getExistingDirectory(this,tr("Choose output folder"),ui->lineEdit_outputPath->text());if(folder.isEmpty())return;ui->lineEdit_outputPath->setText(folder);ui->checkBox_OutPath_isEnabled->setChecked(true);chooseFolder->setChecked(true);wizardOutputPath->setText(fontMetrics().elidedText(folder,Qt::ElideMiddle,360));Wizard_Refresh();});
    auto finish=optionCard(":/wizard/icons/wizard/folder.svg",tr("After finishing"),tr("Reveal the output folder when all files are ready.")); auto *openSwitch=new ToggleSwitch(finish.first); openSwitch->setAccessibleName(tr("Open output folder when finished")); openSwitch->setChecked(ui->checkBox_AutoOpenOutputPath->isChecked()); openSwitch->setOffset(openSwitch->isChecked()); finish.second->itemAt(0)->layout()->addWidget(openSwitch); connect(openSwitch,&QAbstractButton::toggled,ui->checkBox_AutoOpenOutputPath,&QCheckBox::setChecked);
    optionsLayout->addStretch();
    scroll->setWidget(optionsContent); optionsOuter->addWidget(scroll,1); wizardStack->addWidget(optionsPage);

    auto *createPage=new QWidget(wizardStack); auto *create=new QVBoxLayout(createPage); create->setContentsMargins(0,0,0,0); create->setSpacing(12); addPageHeader(create,tr("Create"),tr("Review your choices, then let Waifu2x-Mac do the rest.")); QVBoxLayout *summaryBox; wizardSummaryCard=cardWidget(createPage,&summaryBox,true); auto *summaryHead=new QHBoxLayout;auto *summaryHeader=new QLabel(tr("SUMMARY"),wizardSummaryCard); summaryHeader->setObjectName("sectionHeader");summaryHead->addWidget(summaryHeader);summaryHead->addStretch();auto *summaryAdvanced=new AdvancedButton(tr("Advanced…"),wizardSummaryCard);summaryAdvanced->setIcon(QIcon(":/wizard/icons/wizard/sliders.svg"));connect(summaryAdvanced,&QPushButton::clicked,this,[this]{Wizard_ShowAdvanced();});wizardAdvancedButtons<<summaryAdvanced;summaryHead->addWidget(summaryAdvanced);summaryBox->addLayout(summaryHead); wizardSummary=new QLabel(wizardSummaryCard); wizardSummary->setWordWrap(true); wizardSummary->setTextFormat(Qt::RichText); summaryBox->addWidget(wizardSummary);wizardSummaryOutputPath=new QLabel(wizardSummaryCard);wizardSummaryOutputPath->setObjectName("caption");wizardSummaryOutputPath->setWordWrap(true);wizardSummaryOutputPath->setTextInteractionFlags(Qt::TextSelectableByMouse);summaryBox->addWidget(wizardSummaryOutputPath); ui->pushButton_Start->setParent(wizardSummaryCard); ui->pushButton_Start->setObjectName("primary"); ui->pushButton_Start->setStyleSheet(QString()); ui->pushButton_Start->setText(tr("Start upscaling")); ui->pushButton_Start->setIcon(QIcon());ui->pushButton_Start->setSizePolicy(QSizePolicy::Expanding,QSizePolicy::Fixed); ui->pushButton_Start->setFixedHeight(46); summaryBox->addWidget(ui->pushButton_Start); create->addWidget(wizardSummaryCard);
    wizardRunArea=new QWidget(createPage); auto *run=new QVBoxLayout(wizardRunArea); run->setContentsMargins(0,0,0,0); run->setSpacing(12); auto *runStatus=new QWidget(wizardRunArea); runStatus->setObjectName("runStatusRow"); auto *runCards=new QHBoxLayout(runStatus); runCards->setContentsMargins(0,0,0,0); runCards->setSpacing(12); QVBoxLayout *progressBox; auto *progressCard=cardWidget(runStatus,&progressBox,true); progressCard->setFixedWidth(245); auto *ring=new ProgressRing(progressCard); progressBox->addWidget(ring,0,Qt::AlignHCenter);auto updateRing=[ring,this]{const int total=ui->progressBar->maximum()-ui->progressBar->minimum();const int currentTotal=ui->progressBar_CurrentFile->maximum()-ui->progressBar_CurrentFile->minimum();const double current=currentTotal>0?double(ui->progressBar_CurrentFile->value()-ui->progressBar_CurrentFile->minimum())/currentTotal:0.0;const double done=ui->progressBar->value()-ui->progressBar->minimum()+current;ring->animateTo(total>0?qRound(100.0*done/total):0);};connect(ui->progressBar,&QProgressBar::valueChanged,ring,[updateRing](int){updateRing();});connect(ui->progressBar_CurrentFile,&QProgressBar::valueChanged,ring,[updateRing](int){updateRing();});
    auto *stats=new QWidget(progressCard);auto *statsLayout=new QGridLayout(stats);statsLayout->setContentsMargins(0,0,0,0);statsLayout->setHorizontalSpacing(12);statsLayout->setVerticalSpacing(6);const QStringList statNames={tr("Files done"),tr("Elapsed"),tr("Remaining")};const QList<QLabel*> statValues={ui->label_progressBar_filenum,ui->label_TimeCost,ui->label_TimeRemain};for(int i=0;i<statValues.size();++i){auto *name=new QLabel(statNames[i],stats);name->setObjectName("progressMeta");statValues[i]->setParent(stats);statValues[i]->setProperty("progressMeta",true);statValues[i]->setFrameShape(QFrame::NoFrame);statValues[i]->setAlignment(Qt::AlignRight|Qt::AlignVCenter);statValues[i]->setSizePolicy(QSizePolicy::Preferred,QSizePolicy::Fixed);statsLayout->addWidget(name,i,0);statsLayout->addWidget(statValues[i],i,1);}statsLayout->setColumnStretch(1,1);progressBox->addWidget(stats);ui->label_ETA->hide();
    ui->groupBox_CurrentFile->setParent(progressCard);ui->groupBox_CurrentFile->setTitle(tr("Preparing…"));ui->groupBox_CurrentFile->setVisible(true);ui->groupBox_CurrentFile->setMinimumHeight(62);ui->groupBox_CurrentFile->setStyleSheet("QGroupBox{border:0;margin-top:14px;}QGroupBox::title{subcontrol-origin:margin;left:0;}");auto *currentLayout=qobject_cast<QGridLayout*>(ui->groupBox_CurrentFile->layout());currentLayout->removeWidget(ui->progressBar_CurrentFile);currentLayout->removeWidget(ui->label_FrameProgress_CurrentFile);ui->progressBar_CurrentFile->setRange(0,1);ui->progressBar_CurrentFile->setValue(0);ui->progressBar_CurrentFile->setTextVisible(false);currentLayout->addWidget(ui->progressBar_CurrentFile,0,0);ui->label_FrameProgress_CurrentFile->setText(tr("—"));ui->label_FrameProgress_CurrentFile->setProperty("progressMeta",true);ui->label_FrameProgress_CurrentFile->setFrameShape(QFrame::NoFrame);currentLayout->addWidget(ui->label_FrameProgress_CurrentFile,0,1);currentLayout->setColumnStretch(0,1);for(QLabel *label:{ui->label_TimeCost_CurrentFile,ui->label_TimeRemain_CurrentFile,ui->label_ETA_CurrentFile})label->hide();progressBox->addWidget(ui->groupBox_CurrentFile);
    ui->pushButton_Stop->setParent(progressCard);ui->pushButton_Stop->setObjectName("dangerSecondary");ui->pushButton_Stop->setStyleSheet(QString());ui->pushButton_Stop->setText(tr("Stop"));ui->pushButton_Stop->setIcon(QIcon());progressBox->addWidget(ui->pushButton_Stop);progressBox->addStretch();ui->pushButton_ForceRetry->hide();runCards->addWidget(progressCard);run->addWidget(runStatus,1);wizardDetailsButton=new QPushButton(tr("Show details"),wizardRunArea);wizardDetailsButton->setObjectName("detailsButton");wizardDetailsButton->setCheckable(true);run->addWidget(wizardDetailsButton);QVBoxLayout *detailsBox;auto *detailsCard=cardWidget(wizardRunArea,&detailsBox);ui->textBrowser->setParent(detailsCard);ui->textBrowser->setObjectName("detailsLog");ui->textBrowser->setStyleSheet(QString());detailsBox->addWidget(ui->textBrowser);detailsCard->hide();run->addWidget(detailsCard);connect(wizardDetailsButton,&QPushButton::toggled,this,[this,detailsCard](bool on){wizardDetailsButton->setText(on?tr("Hide details"):tr("Show details"));detailsCard->setVisible(on);});wizardRunArea->hide();create->addWidget(wizardRunArea,1);
    wizardDoneArea=cardWidget(createPage,nullptr,true); auto *done=qobject_cast<QVBoxLayout*>(wizardDoneArea->layout()); done->setContentsMargins(28,28,28,28); wizardDoneMark=new QLabel(QString::fromUtf8("✓"),wizardDoneArea); wizardDoneMark->setObjectName("doneMark"); wizardDoneMark->setFixedSize(72,72); wizardDoneMark->setAlignment(Qt::AlignCenter); wizardDoneTitle=new QLabel(tr("All done"),wizardDoneArea); wizardDoneTitle->setObjectName("doneTitle"); wizardDoneTitle->setAlignment(Qt::AlignCenter); wizardDoneSubtitle=new QLabel(wizardDoneArea); wizardDoneSubtitle->setObjectName("doneSubtitle"); wizardDoneSubtitle->setAlignment(Qt::AlignCenter); wizardDoneSummary=new QLabel(wizardDoneArea); wizardDoneSummary->setObjectName("caption"); wizardDoneSummary->setAlignment(Qt::AlignCenter); wizardDoneSummary->setWordWrap(true);wizardDoneSummary->setTextInteractionFlags(Qt::TextSelectableByMouse); auto *doneButtons=new QHBoxLayout; auto *reveal=new QPushButton(tr("Reveal in Finder"),wizardDoneArea); reveal->setObjectName("primary");auto *openFolder=new QPushButton(tr("Open output folder"),wizardDoneArea); auto *startOver=new QPushButton(tr("Start over"),wizardDoneArea); connect(reveal,&QPushButton::clicked,this,[this]{const QString path=wizardDoneArea->property("firstOutputPath").toString();if(!path.isEmpty())QProcess::startDetached("/usr/bin/open",{"-R",path});else QDesktopServices::openUrl(QUrl::fromLocalFile(wizardDoneArea->property("outputFolder").toString()));});connect(openFolder,&QPushButton::clicked,this,[this]{QDesktopServices::openUrl(QUrl::fromLocalFile(wizardDoneArea->property("outputFolder").toString()));}); connect(startOver,&QPushButton::clicked,this,[this]{on_pushButton_ClearList_clicked();wizardRunning=false;wizardDoneArea->hide();Wizard_ShowStep(0);}); doneButtons->addStretch();doneButtons->addWidget(reveal);doneButtons->addWidget(openFolder);doneButtons->addWidget(startOver);doneButtons->addStretch(); done->addWidget(wizardDoneMark,0,Qt::AlignHCenter);done->addWidget(wizardDoneTitle);done->addWidget(wizardDoneSubtitle);done->addWidget(wizardDoneSummary);done->addLayout(doneButtons); wizardDoneArea->hide(); create->addWidget(wizardDoneArea); create->addStretch(); auto *createScroll=new QScrollArea(wizardStack);createScroll->setWidgetResizable(true);createScroll->setFrameShape(QFrame::NoFrame);createScroll->setWidget(createPage);wizardStack->addWidget(createScroll);

    auto *summaryFlow=new QWidget(wizardSummaryCard);auto *flow=new QHBoxLayout(summaryFlow);flow->setContentsMargins(0,4,0,4);flow->setSpacing(10);auto flowNode=[summaryFlow](QLabel **image,QLabel **label){auto *node=new QWidget(summaryFlow);node->setObjectName("flowNode");auto *box=new QVBoxLayout(node);box->setContentsMargins(12,10,12,10);*image=new QLabel(node);(*image)->setFixedSize(76,58);(*image)->setAlignment(Qt::AlignCenter);*label=new QLabel(node);(*label)->setObjectName("caption");(*label)->setAlignment(Qt::AlignCenter);(*label)->setWordWrap(true);box->addWidget(*image,0,Qt::AlignCenter);box->addWidget(*label);return node;};flow->addWidget(flowNode(&wizardFlowSourceImage,&wizardFlowSourceSize),1);auto *arrow1=new QLabel(summaryFlow);arrow1->setPixmap(svgPixmap(":/wizard/icons/wizard/arrow-right.svg",QColor("#0A84FF"),QSize(24,24)));flow->addWidget(arrow1);flow->addWidget(flowNode(&wizardFlowEngineIcon,&wizardFlowEngineName),1);auto *arrow2=new QLabel(summaryFlow);arrow2->setPixmap(svgPixmap(":/wizard/icons/wizard/arrow-right.svg",QColor("#0A84FF"),QSize(24,24)));flow->addWidget(arrow2);flow->addWidget(flowNode(&wizardFlowResultImage,&wizardFlowResultSize),1);summaryBox->insertWidget(1,summaryFlow);ui->pushButton_Start->setIcon(QIcon(svgPixmap(":/wizard/icons/wizard/arrow-right.svg",Qt::white,QSize(18,18))));wizardSpeedLabel=new QLabel(tr("Waiting for speed data…"),progressCard);wizardSpeedLabel->setObjectName("caption");wizardSpeedLabel->setAlignment(Qt::AlignCenter);progressBox->insertWidget(2,wizardSpeedLabel);wizardDoneGallery=new QWidget(wizardDoneArea);wizardDoneGallery->setObjectName("doneGallery");auto *doneGalleryLayout=new QVBoxLayout(wizardDoneGallery);doneGalleryLayout->setContentsMargins(0,8,0,8);doneGalleryLayout->setSpacing(10);done->insertWidget(4,wizardDoneGallery);
    auto *footer=new QHBoxLayout;auto *advanced=new AdvancedButton(tr("Advanced…"),right);advanced->setObjectName("advancedFooter");advanced->setIcon(QIcon(":/wizard/icons/wizard/sliders.svg"));connect(advanced,&QPushButton::clicked,this,[this]{Wizard_ShowAdvanced();});wizardAdvancedButtons<<advanced; wizardBackButton=new QPushButton(tr("Back"),right); wizardNextButton=new QPushButton(tr("Next"),right); wizardNextButton->setObjectName("primary"); connect(wizardBackButton,&QPushButton::clicked,this,[this]{Wizard_ShowStep(wizardCurrentStep-1);}); connect(wizardNextButton,&QPushButton::clicked,this,[this]{if(!wizardNextButton->property("blocked").toBool())Wizard_ShowStep(wizardCurrentStep+1);});auto *nextBox=new QVBoxLayout;nextBox->setSpacing(2);nextBox->addWidget(wizardNextButton);wizardNextHint=new QLabel(tr("Add at least one file to continue"),right);wizardNextHint->setObjectName("helper");wizardNextHint->setAlignment(Qt::AlignRight);nextBox->addWidget(wizardNextHint); footer->addStretch();footer->addWidget(advanced);footer->addWidget(wizardBackButton);footer->addLayout(nextBox);rightLayout->addLayout(footer);rootLayout->addWidget(right,1);
    for(QComboBox *w:wizardRoot->findChildren<QComboBox*>()){w->setFixedHeight(36);fitComboPopup(w);}for(QSpinBox *w:wizardRoot->findChildren<QSpinBox*>()){w->setFixedHeight(36);w->setButtonSymbols(QAbstractSpinBox::NoButtons);}for(QDoubleSpinBox *w:wizardRoot->findChildren<QDoubleSpinBox*>()){w->setFixedHeight(36);w->setButtonSymbols(QAbstractSpinBox::NoButtons);}auto *focusFilter=new KeyboardFocusFilter(wizardRoot);qApp->installEventFilter(focusFilter);
    ui->centralwidget->layout()->addWidget(wizardRoot); ui->splitter_4->hide(); auto *enter=new QShortcut(QKeySequence(Qt::Key_Return),wizardRoot);connect(enter,&QShortcut::activated,this,[this]{if(!wizardRunning&&wizardCurrentStep<3&&!wizardNextButton->property("blocked").toBool())Wizard_ShowStep(wizardCurrentStep+1);}); auto *keypad=new QShortcut(QKeySequence(Qt::Key_Enter),wizardRoot);connect(keypad,&QShortcut::activated,enter,&QShortcut::activated);auto *openFiles=new QShortcut(QKeySequence("Meta+O"),wizardRoot);connect(openFiles,&QShortcut::activated,this,&MainWindow::on_pushButton_BrowserFile_clicked);auto removeSelected=[this]{QListWidgetItem *item=wizardFileGrid->currentItem();if(!item||wizardRunning)return;const int type=QStringList{"IMG","GIF","VID"}.indexOf(item->data(TypeRole).toString()),row=item->data(RowRole).toInt();curRow_image=type==0?row:-1;curRow_gif=type==1?row:-1;curRow_video=type==2?row:-1;on_pushButton_RemoveItem_clicked();Wizard_Refresh();};for(const QString &sequence:{QStringLiteral("Meta+Backspace"),QStringLiteral("Meta+Delete")}){auto *remove=new QShortcut(QKeySequence(sequence),wizardRoot);connect(remove,&QShortcut::activated,this,removeSelected);}
    for(QScrollArea *area:wizardRoot->findChildren<QScrollArea*>()){area->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);if(area->widget()){area->widget()->setMinimumWidth(0);area->widget()->setSizePolicy(QSizePolicy::Ignored,QSizePolicy::Preferred);}}
    connect(qApp->styleHints(),&QStyleHints::colorSchemeChanged,this,[this]{Wizard_ApplyTheme();}); Wizard_ApplyTheme(); Wizard_ShowStep(0);
    if(measure){fprintf(stdout,"W2X_PERF BuildWizard: %lld ms\n",buildTimer.elapsed());fflush(stdout);}
}

void MainWindow::Wizard_ApplyTheme()
{
    if(!wizardRoot)return;const Theme t=wizardTheme();QPalette p=wizardRoot->palette();p.setColor(QPalette::Window,QColor(t.bg));p.setColor(QPalette::Base,QColor(t.card));p.setColor(QPalette::Button,QColor(t.fieldBg));p.setColor(QPalette::AlternateBase,QColor(t.sidebar));p.setColor(QPalette::WindowText,QColor(t.text));p.setColor(QPalette::Text,QColor(t.text));p.setColor(QPalette::ButtonText,QColor(t.text));p.setColor(QPalette::PlaceholderText,QColor(t.subtext));p.setColor(QPalette::Mid,QColor(t.border));p.setColor(QPalette::Highlight,QColor(t.accent));p.setColor(QPalette::HighlightedText,Qt::white);wizardRoot->setPalette(p);wizardRoot->setStyleSheet(wizardStyle(t));for(QWidget *widget:wizardRoot->findChildren<QWidget*>())widget->setPalette(p);for(QComboBox *combo:wizardRoot->findChildren<QComboBox*>())fitComboPopup(combo);if(wizardAdvancedDialog){wizardAdvancedDialog->setPalette(p);wizardAdvancedDialog->setStyleSheet(wizardStyle(t));for(QWidget *widget:wizardAdvancedDialog->findChildren<QWidget*>())widget->setPalette(p);for(QComboBox *combo:wizardAdvancedDialog->findChildren<QComboBox*>())fitComboPopup(combo);}wizardFileGrid->setProperty("fieldColor",t.fieldBg);wizardFileGrid->setProperty("borderColor",t.border);wizardFileGrid->viewport()->update();wizardRoot->update();
}

void MainWindow::Wizard_SetDragActive(bool active)
{
    if(!wizardDropCard)return; wizardDropCard->setProperty("dragActive",active); wizardDropCard->style()->unpolish(wizardDropCard);wizardDropCard->style()->polish(wizardDropCard); if(wizardDropTitle)wizardDropTitle->setText(active?tr("Release to add"):tr("Drop files here"));
}

void MainWindow::Wizard_SyncFromLegacy()
{
    if(!wizardRoot)return;int engine=ComboId(ui->comboBox_Engine_Image);if(engine!=5&&(engine<7||engine>9))engine=8;SetComboId(ui->comboBox_Engine_Image,engine);SetComboId(ui->comboBox_Engine_GIF,engine);SetComboId(ui->comboBox_Engine_Video,engine);wizardRoot->setProperty("photoMode",engine==5||(engine==9&&ComboId(ui->comboBox_Model_RealESRGAN)>=7));const double scale=qBound(1.0,ui->doubleSpinBox_ScaleRatio_image->value(),ui->doubleSpinBox_ScaleRatio_image->maximum());ui->doubleSpinBox_ScaleRatio_image->setValue(scale);ui->doubleSpinBox_ScaleRatio_gif->setValue(scale);ui->doubleSpinBox_ScaleRatio_video->setValue(scale);int noise=qBound(0,ui->spinBox_DenoiseLevel_image->value(),3);if(engine==8&&ui->comboBox_Model_RealCUGAN->currentIndex()==0&&noise>0)noise=3;ui->spinBox_DenoiseLevel_image->setValue(noise);ui->spinBox_DenoiseLevel_gif->setValue(noise);ui->spinBox_DenoiseLevel_video->setValue(noise);if(wizardTargetEnabled)Wizard_ApplyTargetSize();Wizard_Refresh();
}

void MainWindow::Wizard_ApplyTargetSize()
{
    if(!wizardTargetEnabled||!wizardTargetWidth||!wizardTargetHeight)return;const int width=wizardTargetWidth->value(),height=wizardTargetHeight->value();ui->spinBox_CustRes_width->setValue(width);ui->spinBox_CustRes_height->setValue(height);ui->comboBox_AspectRatio_custRes->setCurrentIndex(1);ui->checkBox_custres_isAll->setChecked(true);ui->checkBox_AutoSkip_CustomRes->setChecked(true);QSettings().setValue("wizard/targetWidth",width);QSettings().setValue("wizard/targetHeight",height);
    QSize input;for(QStandardItemModel *model:{Table_model_image,Table_model_gif,Table_model_video}){if(!model->rowCount())continue;const QString path=model->index(0,2).data().toString();input=wizardMediaSizeCache.value(wizardMediaSizeKeys.value(path));if(input.isValid())break;}if(input.isValid()){const double required=qMax(double(width)/input.width(),double(height)/input.height());int pass=8;for(int candidate:{2,3,4,8})if(required<=candidate){pass=candidate;break;}ui->doubleSpinBox_ScaleRatio_image->setValue(pass);ui->doubleSpinBox_ScaleRatio_gif->setValue(pass);ui->doubleSpinBox_ScaleRatio_video->setValue(pass);}if(Table_model_image->rowCount()+Table_model_gif->rowCount()+Table_model_video->rowCount())on_pushButton_CustRes_apply_clicked();Wizard_Refresh();
}

void MainWindow::Wizard_SelectEngine(int engine,bool photoMode)
{
    wizardRoot->setProperty("photoMode",photoMode);for(QComboBox *combo:{ui->comboBox_Engine_Image,ui->comboBox_Engine_GIF,ui->comboBox_Engine_Video})SetComboId(combo,engine);Wizard_Refresh();
}

QJsonObject MainWindow::Wizard_State() const
{
    QJsonObject state{{"engine",ComboId(ui->comboBox_Engine_Image)},{"photoMode",wizardRoot->property("photoMode").toBool()},{"scale",ui->doubleSpinBox_ScaleRatio_image->value()},{"noise",ui->spinBox_DenoiseLevel_image->value()},{"target",wizardTargetEnabled},{"targetWidth",wizardTargetWidth?wizardTargetWidth->value():3840},{"targetHeight",wizardTargetHeight?wizardTargetHeight->value():2160},{"cuganModel",ui->comboBox_Model_RealCUGAN->currentIndex()},{"cuganSync",ui->comboBox_SyncGap_RealCUGAN->currentIndex()},{"esrganModel",ComboId(ui->comboBox_Model_RealESRGAN)},{"realsrModel",ui->comboBox_Model_RealsrNCNNVulkan->currentIndex()},{"vfi",ui->checkBox_EnableVFI_Home->isChecked()},{"vfiMultiplier",ui->spinBox_MultipleOfFPS_VFI->value()},{"vfiModel",ui->comboBox_Model_VFI->currentIndex()},{"vfiUhd",ui->checkBox_UHD_VFI->isChecked()},{"vfiGpu",ui->comboBox_GPUID_VFI->currentIndex()},{"vfiTta",ui->checkBox_TTA_VFI->isChecked()},{"imageFormat",ui->comboBox_ImageSaveFormat->currentIndex()},{"imageQuality",ui->spinBox_ImageQualityLevel->value()},{"optGif",ui->checkBox_OptGIF->isChecked()},{"outputEnabled",ui->checkBox_OutPath_isEnabled->isChecked()},{"outputPath",ui->lineEdit_outputPath->text()},{"overwrite",ui->checkBox_OutPath_Overwrite->isChecked()},{"keepName",ui->checkBox_OutPath_KeepOriginalFileName->isChecked()},{"keepParent",ui->checkBox_KeepParentFolder->isChecked()},{"deleteOriginal",ui->checkBox_DelOriginal->isChecked()},{"replaceOriginal",ui->checkBox_ReplaceOriginalFile->isChecked()},{"reprocess",ui->checkBox_ReProcFinFiles->isChecked()},{"autoSkip",ui->checkBox_AutoSkip_CustomRes->isChecked()},{"videoEncoder",ui->lineEdit_encoder_vid->text()},{"pixelFormat",ui->lineEdit_pixformat->text()},{"ffmpegArgs",ui->lineEdit_ExCommand_output->text()},{"threads",ui->spinBox_ThreadNum_image->value()},{"finishAction",ui->comboBox_FinishAction->currentIndex()},{"sound",ui->checkBox_NfSound->isChecked()},{"keepAwake",QSettings().value("wizard/keepAwake",true).toBool()},{"showDetails",QSettings().value("wizard/showDetails",false).toBool()},{"nameTemplate",wizardNameTemplate}};
    const int engine=state["engine"].toInt();if(engine==8){state["tile"]=ui->spinBox_TileSize_RealCUGAN->value();state["gpu"]=ui->spinBox_GPUID_RealCUGAN->value();state["tta"]=ui->checkBox_TTA_RealCUGAN->isChecked();}else if(engine==9){state["tile"]=ui->spinBox_TileSize_RealESRGAN->value();state["gpu"]=ui->spinBox_GPUID_RealESRGAN->value();state["tta"]=ui->checkBox_TTA_RealESRGAN->isChecked();}else if(engine==5){state["tile"]=ui->spinBox_TileSize_RealsrNCNNVulkan->value();state["gpu"]=ui->comboBox_GPUID_RealsrNCNNVulkan->currentText()=="auto"?-2:ui->comboBox_GPUID_RealsrNCNNVulkan->currentText().toInt();state["tta"]=ui->checkBox_TTA_RealsrNCNNVulkan->isChecked();}return state;
}

void MainWindow::Wizard_ApplyState(const QJsonObject &state)
{
    const int engine=state.value("engine").toInt(8);Wizard_SelectEngine(engine,state.value("photoMode").toBool());const double scale=state.value("scale").toDouble(2);for(QDoubleSpinBox *spin:{ui->doubleSpinBox_ScaleRatio_image,ui->doubleSpinBox_ScaleRatio_gif,ui->doubleSpinBox_ScaleRatio_video})spin->setValue(scale);const int noise=state.value("noise").toInt();for(QSpinBox *spin:{ui->spinBox_DenoiseLevel_image,ui->spinBox_DenoiseLevel_gif,ui->spinBox_DenoiseLevel_video})spin->setValue(noise);
    ui->comboBox_Model_RealCUGAN->setCurrentIndex(state.value("cuganModel").toInt());ui->comboBox_SyncGap_RealCUGAN->setCurrentIndex(state.value("cuganSync").toInt());SetComboId(ui->comboBox_Model_RealESRGAN,state.value("esrganModel").toInt());ui->comboBox_Model_RealsrNCNNVulkan->setCurrentIndex(state.value("realsrModel").toInt());ui->checkBox_EnableVFI_Home->setChecked(state.value("vfi").toBool());ui->spinBox_MultipleOfFPS_VFI->setValue(state.value("vfiMultiplier").toInt(2));ui->comboBox_Model_VFI->setCurrentIndex(state.value("vfiModel").toInt());ui->checkBox_UHD_VFI->setChecked(state.value("vfiUhd").toBool());ui->comboBox_GPUID_VFI->setCurrentIndex(state.value("vfiGpu").toInt());ui->checkBox_TTA_VFI->setChecked(state.value("vfiTta").toBool());ui->comboBox_ImageSaveFormat->setCurrentIndex(state.value("imageFormat").toInt());ui->spinBox_ImageQualityLevel->setValue(state.value("imageQuality").toInt(100));ui->checkBox_OptGIF->setChecked(state.value("optGif").toBool());
    ui->checkBox_OutPath_isEnabled->setChecked(state.value("outputEnabled").toBool());ui->lineEdit_outputPath->setText(state.value("outputPath").toString());ui->checkBox_OutPath_Overwrite->setChecked(state.value("overwrite").toBool());ui->checkBox_OutPath_KeepOriginalFileName->setChecked(state.value("keepName").toBool());ui->checkBox_KeepParentFolder->setChecked(state.value("keepParent").toBool());ui->checkBox_DelOriginal->setChecked(state.value("deleteOriginal").toBool());ui->checkBox_ReplaceOriginalFile->setChecked(state.value("replaceOriginal").toBool());ui->checkBox_ReProcFinFiles->setChecked(state.value("reprocess").toBool());ui->checkBox_AutoSkip_CustomRes->setChecked(state.value("autoSkip").toBool(true));ui->lineEdit_encoder_vid->setText(state.value("videoEncoder").toString("libx264"));ui->lineEdit_pixformat->setText(state.value("pixelFormat").toString("yuv420p"));ui->lineEdit_ExCommand_output->setText(state.value("ffmpegArgs").toString("-crf 18"));
    const int threads=state.value("threads").toInt(2);ui->spinBox_ThreadNum_image->setValue(threads);ui->spinBox_ThreadNum_gif_internal->setValue(threads);ui->spinBox_ThreadNum_video_internal->setValue(threads);ui->comboBox_FinishAction->setCurrentIndex(state.value("finishAction").toInt());ui->checkBox_NfSound->setChecked(state.value("sound").toBool(true));QSettings().setValue("wizard/keepAwake",state.value("keepAwake").toBool(true));QSettings().setValue("wizard/showDetails",state.value("showDetails").toBool());wizardNameTemplate=state.value("nameTemplate").toString("{name}_{engine}_{scale}x");QSettings().setValue("wizard/nameTemplate",wizardNameTemplate);
    const int tile=state.value("tile").toInt(),gpu=state.value("gpu").toInt(-2);const bool tta=state.value("tta").toBool();if(engine==8){ui->spinBox_TileSize_RealCUGAN->setValue(tile);ui->spinBox_GPUID_RealCUGAN->setValue(gpu);ui->checkBox_TTA_RealCUGAN->setChecked(tta);}else if(engine==9){ui->spinBox_TileSize_RealESRGAN->setValue(tile);ui->spinBox_GPUID_RealESRGAN->setValue(gpu);ui->checkBox_TTA_RealESRGAN->setChecked(tta);}else if(engine==5){ui->spinBox_TileSize_RealsrNCNNVulkan->setValue(tile);const int index=ui->comboBox_GPUID_RealsrNCNNVulkan->findText(gpu<0?"auto":QString::number(gpu));if(index>=0)ui->comboBox_GPUID_RealsrNCNNVulkan->setCurrentIndex(index);ui->checkBox_TTA_RealsrNCNNVulkan->setChecked(tta);}wizardTargetEnabled=state.value("target").toBool();wizardTargetModeGroup->button(wizardTargetEnabled?1:0)->setChecked(true);wizardScaleControls->setVisible(!wizardTargetEnabled);wizardTargetControls->setVisible(wizardTargetEnabled);wizardTargetWidth->setValue(state.value("targetWidth").toInt(3840));wizardTargetHeight->setValue(state.value("targetHeight").toInt(2160));QSettings().setValue("wizard/targetEnabled",wizardTargetEnabled);if(wizardTargetEnabled)Wizard_ApplyTargetSize();Wizard_Refresh();
}

void MainWindow::Wizard_ApplyPreset(const QString &name)
{
    QJsonObject state=Wizard_State();if(name==tr("Anime wallpaper 4K")){state["engine"]=8;state["photoMode"]=false;state["noise"]=0;state["target"]=true;state["targetWidth"]=3840;state["targetHeight"]=2160;}else if(name==tr("Photo restore")){state["engine"]=9;state["photoMode"]=true;state["esrganModel"]=8;state["scale"]=2;state["target"]=false;}else if(name==tr("Quick preview")){state["engine"]=7;state["photoMode"]=false;state["scale"]=2;state["target"]=false;}else if(name==tr("Smooth GIF")){state["engine"]=8;state["photoMode"]=false;state["scale"]=2;state["target"]=false;state["vfi"]=true;state["vfiMultiplier"]=2;state["optGif"]=true;}Wizard_ApplyState(state);
}

void MainWindow::Wizard_ShowStep(int step)
{
    if(!wizardStack||wizardRunning||step<0||step>=wizardStack->count())return;QWidget *page=wizardStack->widget(step);wizardCurrentStep=step;wizardStack->setCurrentIndex(step);for(int i=0;i<wizardStepButtons.size();++i){wizardStepButtons[i]->setProperty("stepState",i<step?2:i==step?1:0);wizardStepButtons[i]->setEnabled(i<=step);wizardStepButtons[i]->update();}wizardBackButton->setVisible(step>0);wizardNextButton->setVisible(step<3);if(auto *advanced=wizardRoot->findChild<QPushButton *>("advancedFooter"))advanced->setVisible(step==1||step==2);if(step!=3&&wizardFilesArea->parentWidget()!=wizardFilesPage){wizardFilesArea->setParent(wizardFilesPage);qobject_cast<QVBoxLayout*>(wizardFilesPage->layout())->addWidget(wizardFilesArea,1);}page->updateGeometry();Wizard_Refresh();if(step==1)QTimer::singleShot(0,this,[this]{Wizard_RequestPreview(false);});
}

void MainWindow::Wizard_Refresh()
{
    if(!wizardRoot)return;wizardRefreshDirty=true;if(wizardRefreshTimer&&!wizardRefreshTimer->isActive())wizardRefreshTimer->start(0);
}

void MainWindow::Wizard_RefreshNow()
{
    if(!wizardRoot)return;
    if(wizardCurrentStep!=1&&(wizardPreviewProcess||(wizardPreviewTimer&&wizardPreviewTimer->isActive())))Wizard_CancelPreview();
    refreshRecent(wizardRecentArea,Table_model_image->rowCount()+Table_model_gif->rowCount()+Table_model_video->rowCount()>0);
    if(wizardSessionFiles){const int count=Table_model_image->rowCount()+Table_model_gif->rowCount()+Table_model_video->rowCount(),engine=ComboId(ui->comboBox_Engine_Image);wizardSessionFiles->setText(count==1?tr("1 file"):tr("%1 files").arg(count));wizardSessionEngine->setText(tr("%1 · %2×").arg(engine==7?tr("MetalFX"):engine==8?tr("Real-CUGAN"):engine==9?tr("Real-ESRGAN"):tr("RealSR")).arg(ui->doubleSpinBox_ScaleRatio_image->value(),0,'f',1));}
    if(wizardRunning&&wizardFileGrid){const int range=ui->progressBar_CurrentFile->maximum()-ui->progressBar_CurrentFile->minimum(),percent=range>0?qRound(100.0*(ui->progressBar_CurrentFile->value()-ui->progressBar_CurrentFile->minimum())/range):0;for(int i=0;i<wizardFileGrid->count();++i)if(wizardFileGrid->item(i)->data(StatusRole).toString().contains("Processing",Qt::CaseInsensitive))wizardFileGrid->item(i)->setData(ProgressRole,percent);}
    if(wizardFlowSourceImage){QString source;for(QStandardItemModel *model:{Table_model_image,Table_model_gif,Table_model_video})if(model->rowCount()){source=model->index(0,2).data().toString();break;}const QSize input=wizardMediaSizeCache.value(wizardMediaSizeKeys.value(source));const double flowScale=ui->doubleSpinBox_ScaleRatio_image->value();const QSize output=wizardTargetEnabled&&input.isValid()?input.scaled(QSize(wizardTargetWidth->value(),wizardTargetHeight->value()),Qt::KeepAspectRatio):QSize(qRound(input.width()*flowScale),qRound(input.height()*flowScale));QPixmap pix=wizardThumbnailCache.value(wizardThumbnailKeys.value(source));if(pix.isNull())pix=svgPixmap(":/wizard/icons/wizard/image.svg",wizardRoot->palette().color(QPalette::PlaceholderText),QSize(54,54));wizardFlowSourceImage->setPixmap(pix.scaled(wizardFlowSourceImage->size(),Qt::KeepAspectRatio,Qt::SmoothTransformation));wizardFlowResultImage->setPixmap(pix.scaled(wizardFlowResultImage->size(),Qt::KeepAspectRatio,Qt::SmoothTransformation));wizardFlowSourceSize->setText(input.isValid()?tr("Original\n%1 × %2").arg(input.width()).arg(input.height()):tr("Original"));wizardFlowResultSize->setText(output.isValid()?tr("Result\n%1 × %2").arg(output.width()).arg(output.height()):tr("Result · %1×").arg(flowScale,0,'f',1));const int flowEngine=ComboId(ui->comboBox_Engine_Image);const QString flowName=flowEngine==7?tr("MetalFX"):flowEngine==8?tr("Real-CUGAN"):flowEngine==9?tr("Real-ESRGAN"):tr("RealSR");const QString icon=flowEngine==7?":/wizard/icons/wizard/bolt.svg":flowEngine==8?":/wizard/icons/wizard/sparkles.svg":flowEngine==9?":/wizard/icons/wizard/sharp.svg":":/wizard/icons/wizard/camera.svg";wizardFlowEngineIcon->setPixmap(svgPixmap(icon,QColor("#0A84FF"),QSize(46,46)));wizardFlowEngineName->setText(flowName+tr("\n%1×").arg(flowScale,0,'f',1));}if(wizardRunning&&wizardSpeedLabel&&wizardRunStartedMs>0){const double minutes=(QDateTime::currentMSecsSinceEpoch()-wizardRunStartedMs)/60000.0;const int completed=qMax(0,ui->progressBar->value()-ui->progressBar->minimum());wizardSpeedLabel->setText(minutes>0&&completed>0?tr("%1 files/min").arg(completed/minutes,0,'f',1):tr("Measuring speed…"));}
    const int headerTotal=Table_model_image->rowCount()+Table_model_gif->rowCount()+Table_model_video->rowCount();const QString headerFileCount=headerTotal==1?tr("1 file"):tr("%1 files").arg(headerTotal);qint64 headerBytes=0;for(auto it=wizardFileSizeCache.cbegin();it!=wizardFileSizeCache.cend();++it)if(it.value()>0)headerBytes+=it.value();const int headerEngine=ComboId(ui->comboBox_Engine_Image);const QString headerEngineName=headerEngine==7?tr("MetalFX"):headerEngine==8?tr("Real-CUGAN"):headerEngine==9?tr("Real-ESRGAN"):tr("RealSR");const int currentRange=ui->progressBar_CurrentFile->maximum()-ui->progressBar_CurrentFile->minimum(),currentPercent=currentRange>0?qRound(100.0*(ui->progressBar_CurrentFile->value()-ui->progressBar_CurrentFile->minimum())/currentRange):0;for(QLabel *chip:wizardRoot->findChildren<QLabel*>("headerChip")){switch(chip->property("stepHeaderChip").toInt()){case 0:chip->setText(tr("%1 · %2").arg(headerFileCount,QLocale().formattedDataSize(headerBytes)));break;case 1:chip->setText(tr("%1 · %2×").arg(headerEngineName).arg(ui->doubleSpinBox_ScaleRatio_image->value(),0,'f',1));break;case 2:chip->setText(tr("Estimate ready"));break;default:chip->setText(wizardDoneArea&&wizardDoneArea->isVisible()?tr("Done - %1").arg(headerFileCount):wizardRunning?tr("Processing %1 %").arg(currentPercent):tr("Ready to create"));break;}}
    if(!wizardRoot)return;for(QTableView *table:{ui->tableView_image,ui->tableView_gif,ui->tableView_video})table->hide();const QList<QStandardItemModel*> models={Table_model_image,Table_model_gif,Table_model_video};const QStringList typeNames={"IMG","GIF","VID"};const int images=models[0]->rowCount(),gifs=models[1]->rowCount(),videos=models[2]->rowCount(),total=images+gifs+videos;const QList<int> counts={images,gifs,videos};const QStringList names={tr("Images"),tr("GIFs"),tr("Videos")};int filter=wizardRoot->property("fileFilter").isValid()?wizardRoot->property("fileFilter").toInt():-1;if(filter<0||filter>2||counts[filter]==0){filter=-1;for(int i=0;i<3;++i)if(counts[i]){filter=i;break;}wizardRoot->setProperty("fileFilter",filter);}for(int i=0;i<3;++i){wizardFileButtons[i]->setText(tr("%1 (%2)").arg(names[i]).arg(counts[i]));wizardFileButtons[i]->setVisible(counts[i]>0);QSignalBlocker b(wizardFileButtons[i]);wizardFileButtons[i]->setChecked(i==filter);}wizardDropCard->setVisible(total==0);wizardFilesArea->setVisible(total>0&&(wizardCurrentStep==0||wizardRunning));const bool nextBlocked=wizardCurrentStep==0&&total==0;wizardNextButton->setProperty("blocked",nextBlocked);wizardNextButton->setToolTip(nextBlocked?tr("Add at least one file to continue"):QString());if(wizardNextHint)wizardNextHint->setVisible(nextBlocked);if(wizardGeneratePreview)wizardGeneratePreview->setEnabled(total>0);
    QStringList fileKeys;QSet<QString> currentPaths;for(int type=0;type<3;++type)for(int row=0;row<models[type]->rowCount();++row){const QString path=models[type]->index(row,2).data().toString();fileKeys<<QString::number(type)+QChar(0x1f)+path;currentPaths.insert(path);}const QString fileSignature=fileKeys.join(QChar(0x1e));if(fileSignature!=wizardFileListSignature){for(const QString &path:wizardKnownPaths-currentPaths){const QString cacheKey=wizardThumbnailKeys.take(path);wizardThumbnailCache.remove(cacheKey);wizardMediaSizeCache.remove(cacheKey);wizardFileSizeCache.remove(cacheKey);wizardDurationCache.remove(cacheKey);wizardFrameCountCache.remove(cacheKey);wizardAudioSizeCache.remove(cacheKey);wizardMediaSizeKeys.remove(path);}for(const QString &path:currentPaths-wizardKnownPaths){wizardThumbnailKeys.remove(path);wizardMediaSizeKeys.remove(path);}wizardKnownPaths=currentPaths;wizardFileListSignature=fileSignature;if(wizardTargetEnabled&&total)QTimer::singleShot(0,this,&MainWindow::Wizard_ApplyTargetSize);}
    const bool statusMode=wizardRunning&&wizardCurrentStep==3;for(QPushButton *button:wizardFilesArea->findChildren<QPushButton*>())if(button->property("step1Control").toBool())button->setVisible(!statusMode&&(wizardFileButtons.contains(button)?counts[wizardFileButtons.indexOf(button)]>0:true));const QString gridSignature=fileSignature+QChar(0x1d)+QString::number(filter)+QString::number(statusMode);const bool rebuildGrid=gridSignature!=wizardGridSignature;wizardFileGrid->setProperty("statusMode",statusMode);wizardFileGrid->setViewMode(statusMode?QListView::ListMode:QListView::IconMode);wizardFileGrid->setFlow(statusMode?QListView::TopToBottom:QListView::LeftToRight);wizardFileGrid->setWrapping(!statusMode);const int gridWidth=qMax(152,(wizardFileGrid->viewport()->width()-16)/4);wizardFileGrid->setProperty("gridCellWidth",gridWidth);wizardFileGrid->setGridSize(statusMode?QSize():QSize(gridWidth,180));if(rebuildGrid){wizardFileGrid->clear();wizardGridSignature=gridSignature;}
    const QString toolsPath=Current_Path;auto requestThumb=[this,toolsPath](const QString &path,int type){if(path.isEmpty()||wizardThumbnailPending.contains(path))return;const QString key=mediaCacheKey(path);if(wizardThumbnailKeys.value(path)==key)return;const QString oldKey=wizardThumbnailKeys.take(path);wizardMediaSizeKeys.remove(path);wizardThumbnailCache.remove(oldKey);wizardMediaSizeCache.remove(oldKey);wizardFileSizeCache.remove(oldKey);wizardDurationCache.remove(oldKey);wizardFrameCountCache.remove(oldKey);wizardAudioSizeCache.remove(oldKey);wizardThumbnailPending.insert(path);auto *watcher=new QFutureWatcher<MediaResult>(this);connect(watcher,&QFutureWatcher<MediaResult>::finished,this,[this,watcher,path]{const MediaResult result=watcher->result();if(wizardKnownPaths.contains(path)){wizardThumbnailKeys.insert(path,result.cacheKey);wizardMediaSizeKeys.insert(path,result.cacheKey);wizardFileSizeCache.insert(result.cacheKey,result.byteSize);wizardDurationCache.insert(result.cacheKey,result.durationSeconds);wizardFrameCountCache.insert(result.cacheKey,result.frameCount);wizardAudioSizeCache.insert(result.cacheKey,result.audioBytes);if(result.size.isValid())wizardMediaSizeCache.insert(result.cacheKey,result.size);if(!result.image.isNull())wizardThumbnailCache.insert(result.cacheKey,QPixmap::fromImage(result.image));for(int i=0;i<wizardFileGrid->count();++i){QListWidgetItem *item=wizardFileGrid->item(i);if(item->data(PathRole).toString()!=path)continue;if(!result.image.isNull())item->setData(Qt::DecorationRole,wizardThumbnailCache.value(result.cacheKey));if(result.byteSize>=0)item->setData(SizeRole,QLocale().formattedDataSize(result.byteSize));const QString typeName=item->data(TypeRole).toString()=="IMG"?tr("image"):item->data(TypeRole).toString()=="GIF"?tr("GIF"):tr("video");item->setData(Qt::AccessibleTextRole,tr("File %1, %2, %3").arg(QFileInfo(path).fileName(),typeName,item->data(SizeRole).toString()));}wizardFileGrid->viewport()->update();}wizardThumbnailPending.remove(path);watcher->deleteLater();Wizard_Refresh();});watcher->setFuture(QtConcurrent::run([path,type,toolsPath]{return readMedia(path,type,toolsPath);}));};
    QString firstPath;int firstType=-1;for(int type=0;type<3;++type){if(!statusMode&&type!=filter)continue;for(int row=0;row<models[type]->rowCount();++row){const QString path=models[type]->index(row,2).data().toString(),name=models[type]->index(row,0).data().toString(),status=models[type]->index(row,1).data().toString();if(firstPath.isEmpty()){firstPath=path;firstType=type;}requestThumb(path,type);if(!rebuildGrid)continue;const QString output=statusMode&&status.contains("Finished",Qt::CaseInsensitive)?firstOutputFile(path,ui->checkBox_OutPath_isEnabled->isChecked()?ui->lineEdit_outputPath->text():QString()):QString();auto *item=new QListWidgetItem(output.isEmpty()?name:QFileInfo(output).fileName(),wizardFileGrid);item->setData(PathRole,path);item->setData(TypeRole,typeNames[type]);item->setData(RowRole,row);const QString cacheKey=wizardThumbnailKeys.value(path);const qint64 byteSize=wizardFileSizeCache.value(cacheKey,-1);item->setData(SizeRole,byteSize>=0?QLocale().formattedDataSize(byteSize):tr("Loading…"));item->setData(StatusRole,status);item->setData(Qt::AccessibleTextRole,tr("File %1, %2, %3").arg(QFileInfo(path).fileName(),type==0?tr("image"):type==1?tr("GIF"):tr("video"),item->data(SizeRole).toString()));QPixmap pix=wizardThumbnailCache.value(cacheKey);if(pix.isNull())pix=svgPixmap(type==0?":/wizard/icons/wizard/image.svg":type==1?":/wizard/icons/wizard/gif.svg":":/wizard/icons/wizard/motion.svg",wizardRoot->palette().color(QPalette::PlaceholderText),QSize(72,72));item->setData(Qt::DecorationRole,pix);}}
    if(!rebuildGrid)for(int i=0;i<wizardFileGrid->count();++i){QListWidgetItem *item=wizardFileGrid->item(i);const int type=typeNames.indexOf(item->data(TypeRole).toString()),row=item->data(RowRole).toInt();if(type>=0&&row<models[type]->rowCount())item->setData(StatusRole,models[type]->index(row,1).data().toString());}
    const int engine=ComboId(ui->comboBox_Engine_Image);const bool photoMode=wizardRoot->property("photoMode").toBool()||engine==5;for(QPushButton *button:wizardRoot->findChildren<QPushButton*>())if(button->property("engineId").isValid()){const bool isPhoto=button->property("photoCard").toBool();const bool checked=isPhoto?photoMode:(!photoMode&&button->property("engineId").toInt()==engine);if(button->isChecked()!=checked)button->setChecked(checked);if(auto *check=button->findChild<QLabel*>("engineCheck"))check->setVisible(checked);}wizardNoiseRow->setVisible(engine==8);wizardCuganModelRow->setVisible(engine==8);wizardEsrganModelRow->setVisible(engine==9&&!photoMode);wizardPhotoModelRow->setVisible(photoMode);wizardMotionCard->setVisible(gifs>0||videos>0);wizardImageCard->setVisible(images>0);wizardGifCard->setVisible(gifs>0);if(auto *options=wizardRoot->findChild<QWidget*>("optionsGrid"))static_cast<ResponsiveGrid*>(options)->relayout();
    if(wizardParallelFiles){QSignalBlocker b(wizardParallelFiles);wizardParallelFiles->setValue(qBound(wizardParallelFiles->minimum(),ui->spinBox_ThreadNum_image->value(),wizardParallelFiles->maximum()));}if(photoMode&&wizardPhotoModel->count()){int choice=engine==9?900+ComboId(ui->comboBox_Model_RealESRGAN):500+ui->comboBox_Model_RealsrNCNNVulkan->currentIndex();int index=wizardPhotoModel->findData(choice);if(index>=0){QSignalBlocker b(wizardPhotoModel);wizardPhotoModel->setCurrentIndex(index);}}
    const double scale=ui->doubleSpinBox_ScaleRatio_image->value();{QSignalBlocker b(wizardCustomScale);wizardCustomScale->setValue(scale);}wizardSizeGroup->setExclusive(false);for(QAbstractButton *b:wizardSizeGroup->buttons())b->setChecked(!wizardTargetEnabled&&qFuzzyCompare(scale,double(wizardSizeGroup->id(b))));wizardSizeGroup->setExclusive(true);const bool cuganPro=engine==8&&ui->comboBox_Model_RealCUGAN->currentIndex()==0;int noise=qBound(0,ui->spinBox_DenoiseLevel_image->value(),3);if(cuganPro&&(noise==1||noise==2)){noise=3;ui->spinBox_DenoiseLevel_image->setValue(3);ui->spinBox_DenoiseLevel_gif->setValue(3);ui->spinBox_DenoiseLevel_video->setValue(3);}wizardNoiseGroup->setExclusive(false);for(QAbstractButton *b:wizardNoiseGroup->buttons()){const int id=wizardNoiseGroup->id(b);b->setVisible(!cuganPro||id==0||id==3);if(id==3){b->setText(cuganPro?tr("Strong"):tr("High"));b->setAccessibleName(b->text());}b->setChecked(id==noise);}wizardNoiseGroup->setExclusive(true);wizardScaleCaption->setText(wizardTargetEnabled?tr("Fit inside %1 × %2").arg(wizardTargetWidth->value()).arg(wizardTargetHeight->value()):tr("Output will be %1× larger").arg(scale,0,'f',1));auto outputSize=[this,scale](const QSize &input){return wizardTargetEnabled?input.scaled(QSize(wizardTargetWidth->value(),wizardTargetHeight->value()),Qt::KeepAspectRatio):QSize(qRound(input.width()*scale),qRound(input.height()*scale));};
    if(!firstPath.isEmpty()){const QString cacheKey=wizardThumbnailKeys.value(firstPath);QPixmap preview=wizardThumbnailCache.value(cacheKey);if(preview.isNull())preview=svgPixmap(firstType==0?":/wizard/icons/wizard/image.svg":firstType==1?":/wizard/icons/wizard/gif.svg":":/wizard/icons/wizard/motion.svg",wizardRoot->palette().color(QPalette::PlaceholderText),QSize(48,48));wizardPreviewImage->setPixmap(preview.scaled(wizardPreviewImage->size(),Qt::KeepAspectRatio,Qt::SmoothTransformation));const QSize input=wizardMediaSizeCache.value(wizardMediaSizeKeys.value(firstPath));if(input.isValid()){const QSize output=outputSize(input);const double mb=output.width()*output.height()*4.0/1000000.0;wizardPreviewInput->setText(tr("%1 × %2").arg(input.width()).arg(input.height()));wizardPreviewOutput->setText(tr("→ %1 × %2 · about %3 MB").arg(output.width()).arg(output.height()).arg(mb,0,'f',1));}else{wizardPreviewInput->setText(QFileInfo(firstPath).fileName());wizardPreviewOutput->setText(wizardTargetEnabled?tr("→ Fit inside %1 × %2").arg(wizardTargetWidth->value()).arg(wizardTargetHeight->value()):tr("→ %1× output").arg(scale,0,'f',1));}}else{wizardPreviewImage->clear();wizardPreviewInput->setText(tr("Add a file to preview dimensions"));wizardPreviewOutput->clear();}
    const QString engineName=engine==5?tr("RealSR (Photos)"):engine==7?tr("MetalFX (Fast)"):photoMode?tr("Real-ESRGAN (Photos)"):engine==9?tr("Real-ESRGAN (Sharp)"):tr("Real-CUGAN (Best for anime)");const QStringList noiseNames={tr("Off"),tr("Low"),tr("Medium"),cuganPro?tr("Strong"):tr("High")};const QString motion=ui->checkBox_EnableVFI_Home->isChecked()?tr("%1× frames").arg(ui->spinBox_MultipleOfFPS_VFI->value()):tr("Off");const QString destination=ui->checkBox_OutPath_isEnabled->isChecked()?ui->lineEdit_outputPath->text():tr("Next to original files");const QString destinationPath=ui->checkBox_OutPath_isEnabled->isChecked()?ui->lineEdit_outputPath->text():(firstPath.isEmpty()?QString():QFileInfo(firstPath).absolutePath());const QSize firstSize=wizardMediaSizeCache.value(wizardMediaSizeKeys.value(firstPath)),resultSize=firstSize.isValid()?outputSize(firstSize):QSize();const QString sizeSummary=firstSize.isValid()?tr("%1 x %2 → %3 x %4").arg(firstSize.width()).arg(firstSize.height()).arg(resultSize.width()).arg(resultSize.height()):(wizardTargetEnabled?tr("Fit inside %1 x %2").arg(wizardTargetWidth->value()).arg(wizardTargetHeight->value()):tr("%1× larger").arg(scale,0,'f',1));QStringList countParts;if(images)countParts<<(images==1?tr("1 image"):tr("%1 images").arg(images));if(gifs)countParts<<(gifs==1?tr("1 GIF"):tr("%1 GIFs").arg(gifs));if(videos)countParts<<(videos==1?tr("1 video"):tr("%1 videos").arg(videos));const QColor sub=wizardRoot->palette().color(QPalette::PlaceholderText);auto row=[sub](const QString &label,const QString &value){return QString("<tr><td style='color:%1;padding:6px 16px 6px 0'>%2</td><td align='right' style='padding:6px 0'>%3</td></tr>").arg(sub.name(),label.toHtmlEscaped(),value.toHtmlEscaped());};wizardSummary->setText("<table width='100%' cellspacing='0'>"+row(tr("Files"),countParts.join(tr(", ")))+row(tr("Upscaler"),engineName)+row(tr("Size"),sizeSummary)+row(tr("Noise reduction"),engine==8?noiseNames[noise]:tr("Not applicable"))+row(tr("Smoother motion"),motion)+row(tr("Save to"),destination)+"</table>");wizardSummaryOutputPath->setText(destinationPath.isEmpty()?QString():tr("Output: %1").arg(QDir::toNativeSeparators(destinationPath)));
    if(wizardPresetRow){QJsonObject current=Wizard_State();for(QPushButton *button:wizardPresetRow->findChildren<QPushButton*>()){bool active=false;const QString builtIn=button->property("presetName").toString();if(builtIn==tr("Anime wallpaper 4K"))active=engine==8&&noise==0&&wizardTargetEnabled&&wizardTargetWidth->value()==3840&&wizardTargetHeight->value()==2160;else if(builtIn==tr("Photo restore"))active=engine==9&&photoMode&&ComboId(ui->comboBox_Model_RealESRGAN)==8&&!wizardTargetEnabled&&qFuzzyCompare(scale,2.0);else if(builtIn==tr("Quick preview"))active=engine==7&&!wizardTargetEnabled&&qFuzzyCompare(scale,2.0);else if(builtIn==tr("Smooth GIF"))active=engine==8&&!wizardTargetEnabled&&qFuzzyCompare(scale,2.0)&&ui->checkBox_EnableVFI_Home->isChecked()&&ui->spinBox_MultipleOfFPS_VFI->value()==2&&ui->checkBox_OptGIF->isChecked();else if(!button->property("presetJson").toString().isEmpty()){QJsonObject saved=QJsonDocument::fromJson(button->property("presetJson").toString().toUtf8()).object();saved.remove("presetName");active=saved==current;}if(button->isCheckable()){QSignalBlocker blocker(button);button->setChecked(active);}}}
    const auto crfMatch=QRegularExpression("-crf\\s+(\\d+)").match(ui->lineEdit_ExCommand_output->text());const int tile=engine==8?ui->spinBox_TileSize_RealCUGAN->value():engine==9?ui->spinBox_TileSize_RealESRGAN->value():engine==5?ui->spinBox_TileSize_RealsrNCNNVulkan->value():0;const bool advancedChanged=tile!=0||(engine==8&&ui->spinBox_GPUID_RealCUGAN->value()!=-2)||(engine==9&&ui->spinBox_GPUID_RealESRGAN->value()!=-2)||(engine==8&&ui->checkBox_TTA_RealCUGAN->isChecked())||(engine==9&&ui->checkBox_TTA_RealESRGAN->isChecked())||ui->checkBox_OutPath_Overwrite->isChecked()||ui->checkBox_DelOriginal->isChecked()||ui->checkBox_ReplaceOriginalFile->isChecked()||ui->lineEdit_encoder_vid->text().contains("265")||(crfMatch.hasMatch()&&crfMatch.captured(1).toInt()!=18)||ui->spinBox_ThreadNum_image->value()!=2||(wizardNameTemplate!="{name}_{engine}_{scale}x");for(QPushButton *button:wizardAdvancedButtons){button->setProperty("changed",advancedChanged);button->update();}
    qint64 totalBytes=0;for(const QString &path:wizardKnownPaths){const QString key=wizardThumbnailKeys.value(path);const qint64 bytes=wizardFileSizeCache.value(key,-1);if(bytes>0)totalBytes+=bytes;}if(wizardFilesFooter){QStringList kinds;if(images)kinds<<(images==1?tr("1 photo"):tr("%1 photos").arg(images));if(gifs)kinds<<(gifs==1?tr("1 GIF"):tr("%1 GIFs").arg(gifs));if(videos)kinds<<(videos==1?tr("1 video"):tr("%1 videos").arg(videos));wizardFilesFooter->setText(tr("%1 · %2 · %3").arg(total==1?tr("1 file"):tr("%1 files").arg(total),QLocale().formattedDataSize(totalBytes),kinds.join(tr(", "))));}if(!statusMode)wizardFileGrid->setGridSize(QSize(gridWidth,218));for(int i=0;i<wizardFileGrid->count();++i){auto *item=wizardFileGrid->item(i);const QString path=item->data(PathRole).toString(),key=wizardMediaSizeKeys.value(path);const int type=typeNames.indexOf(item->data(TypeRole).toString());const QString caption=Wizard_FormatMediaCaption(type,wizardMediaSizeCache.value(key),wizardDurationCache.value(key,-1),wizardFrameCountCache.value(key,-1));item->setData(SizeRole,caption);item->setData(Qt::AccessibleTextRole,tr("File %1, %2, %3").arg(QFileInfo(path).fileName(),type==0?tr("image"):type==1?tr("GIF"):tr("video"),caption));}
    qint64 outputPixels=0;for(const QString &path:wizardKnownPaths){const QSize input=wizardMediaSizeCache.value(wizardMediaSizeKeys.value(path));if(input.isValid()){const QSize output=outputSize(input);outputPixels+=qint64(output.width())*output.height();}}if(wizardEstimateResolution){wizardEstimateResolution->setText(resultSize.isValid()?tr("%1 × %2%3").arg(resultSize.width()).arg(resultSize.height()).arg(total>1?tr(" · %1 MP total").arg(outputPixels/1000000.0,0,'f',1):QString()):tr("Reading input…"));qint64 approximate=0;bool estimateUnknown=false;const int crf=crfMatch.hasMatch()?crfMatch.captured(1).toInt():18;const bool hevc=ui->lineEdit_encoder_vid->text().contains("265");const QStringList estimateTypes={"image","gif","video"};for(int type=0;type<models.size();++type)for(int row=0;row<models[type]->rowCount();++row){const QString path=models[type]->index(row,2).data().toString(),key=wizardMediaSizeKeys.value(path);const QSize input=wizardMediaSizeCache.value(key),output=input.isValid()?outputSize(input):QSize();const qint64 bytes=wizardFileSizeCache.value(key,-1),inPixels=qint64(input.width())*input.height(),outPixels=qint64(output.width())*output.height();const double learned=QSettings().value(QString("estimate/%1").arg(estimateTypes[type]),0).toDouble();const qint64 itemEstimate=Wizard_EstimateBytes(type,bytes,inPixels,outPixels,wizardDurationCache.value(key,-1),wizardAudioSizeCache.value(key),crf,hevc,learned);if(itemEstimate>0)approximate+=itemEstimate;else if(bytes>0)estimateUnknown=true;}if(estimateUnknown)approximate=0;animateMetric(wizardEstimateSize,approximate,[](qint64 bytes){return bytes>0?QObject::tr("about %1").arg(QLocale().formattedDataSize(bytes)):QObject::tr("—");});const double secondsPerMp=QSettings().value("bench/"+QString::number(engine),0).toDouble();const qint64 seconds=secondsPerMp>0&&outputPixels>0?qMax(1,qRound(secondsPerMp*outputPixels/1000000.0)):0;animateMetric(wizardEstimateTime,seconds,[](qint64 value){return value<=0?QObject::tr("After your first run"):value<60?QObject::tr("about %1 s").arg(value):QObject::tr("about %1 min").arg(qMax(1,qRound(value/60.0)));});}if(wizardCurrentStep==1)Wizard_RequestPreview(false);
}

void MainWindow::Wizard_SetPreviewImages(const QImage &before,const QImage &after,const QString &label)
{
    if(wizardCompare&&qEnvironmentVariableIsSet("W2X_SNAPSHOT_DIR"))wizardCompare->setProperty("snapshotReady",true);
    if(!wizardCompare)return;wizardCompare->setImages(before,after,label);if(wizardPreviewStatus)wizardPreviewStatus->setText(tr("Drag the handle or use the arrow keys to compare."));
}

void MainWindow::Wizard_CancelPreview()
{
    ++wizardPreviewSerial;if(wizardPreviewTimer)wizardPreviewTimer->stop();if(wizardPreviewProcess){wizardPreviewProcess->kill();wizardPreviewProcess->deleteLater();wizardPreviewProcess=nullptr;}if(!wizardPreviewDir.isEmpty()){QDir(wizardPreviewDir).removeRecursively();wizardPreviewDir.clear();}
}

void MainWindow::Wizard_RequestPreview(bool immediate)
{
    if(wizardCompare&&qEnvironmentVariableIsSet("W2X_SNAPSHOT_DIR")&&wizardCompare->property("snapshotReady").toBool())return;
    if(!wizardCompare||wizardCurrentStep!=1)return;QString source;for(QStandardItemModel *model:{Table_model_image,Table_model_gif,Table_model_video})if(model->rowCount()){source=model->index(0,2).data().toString();break;}if(source.isEmpty())return;const QFileInfo info(source);const int engine=ComboId(ui->comboBox_Engine_Image);const QString key=QString("%1|%2|%3|%4|%5|%6|%7|%8|%9|%10").arg(source).arg(info.lastModified().toMSecsSinceEpoch()).arg(engine).arg(engine==8?ui->comboBox_Model_RealCUGAN->currentIndex():engine==9?ComboId(ui->comboBox_Model_RealESRGAN):ui->comboBox_Model_RealsrNCNNVulkan->currentIndex()).arg(ui->doubleSpinBox_ScaleRatio_image->value()).arg(ui->spinBox_DenoiseLevel_image->value()).arg((engine==8&&ui->checkBox_TTA_RealCUGAN->isChecked())||(engine==9&&ui->checkBox_TTA_RealESRGAN->isChecked())).arg(wizardTargetEnabled).arg(wizardTargetWidth->value()).arg(wizardTargetHeight->value());if(!immediate&&key==wizardPreviewSettingsKey&&(wizardPreviewTimer->isActive()||wizardPreviewProcess||wizardPreviewAfterCache.contains(key)))return;wizardPreviewSettingsKey=key;if(wizardPreviewAfterCache.contains(key)){Wizard_SetPreviewImages(wizardPreviewBeforeCache.value(key),wizardPreviewAfterCache.value(key),wizardPreviewLabelCache.value(key));if(!wizardPreviewNoteCache.value(key).isEmpty())wizardPreviewStatus->setText(wizardPreviewNoteCache.value(key));return;}Wizard_CancelPreview();wizardPreviewSettingsKey=key;wizardPreviewTimer->start(immediate?0:600);wizardCompare->setLoading(true);wizardPreviewStatus->setText(tr("Preparing a 192 × 192 preview crop…"));
}

QList<int> MainWindow::Wizard_PreviewPassPlan(int engine,double requested)
{
    QList<int> passes;if(requested<=1.0)return passes;const int scale=qMax(2,int(std::ceil(requested)));int maximum,pass;if(engine==5){maximum=Calculate_Temporary_ScaleRatio_RealsrNCNNVulkan(scale);pass=4;}else{maximum=W2xNcnnVulkan_ScaleRatioMax(engine,scale);pass=W2xNcnnVulkan_PassScale(engine,maximum);}for(int factor=1;factor<maximum&&factor<requested;)passes<<pass,factor*=pass;return passes;
}

double MainWindow::Wizard_PreviewEffectiveFactor(const QSize &sourceSize) const
{
    if(!wizardTargetEnabled||!sourceSize.isValid())return qMax(1.0,ui->doubleSpinBox_ScaleRatio_image->value());return std::min(double(wizardTargetWidth->value())/sourceSize.width(),double(wizardTargetHeight->value())/sourceSize.height());
}

void MainWindow::Wizard_RunPreview()
{
    if(wizardCurrentStep!=1)return;QString source;int type=-1;const QList<QStandardItemModel*> models={Table_model_image,Table_model_gif,Table_model_video};for(int i=0;i<models.size();++i)if(models[i]->rowCount()){source=models[i]->index(0,2).data().toString();type=i;break;}if(source.isEmpty()){wizardCompare->setError(tr("Add a file to generate a preview."));return;}const int serial=++wizardPreviewSerial,engine=ComboId(ui->comboBox_Engine_Image);const QString key=wizardPreviewSettingsKey,tools=Current_Path;wizardPreviewDir=Data_Path+"/Preview/"+QUuid::createUuid().toString(QUuid::WithoutBraces);QDir().mkpath(wizardPreviewDir);const QString previewDir=wizardPreviewDir;auto *watcher=new QFutureWatcher<PreviewSource>(this);
    connect(watcher,&QFutureWatcher<PreviewSource>::finished,this,[this,watcher,serial,engine,key,previewDir]{
        const PreviewSource result=watcher->result();watcher->deleteLater();if(serial!=wizardPreviewSerial)return;if(!result.error.isEmpty()||result.crop.isNull()){wizardCompare->setError(result.error.isEmpty()?tr("Unable to read the first file."):result.error);QDir(previewDir).removeRecursively();return;}
        const double requested=Wizard_PreviewEffectiveFactor(result.sourceSize);const QSize target(qMax(1,qRound(result.crop.width()*requested)),qMax(1,qRound(result.crop.height()*requested)));const QImage before=result.crop.scaled(target,Qt::IgnoreAspectRatio,Qt::SmoothTransformation);const QList<int> passes=Wizard_PreviewPassPlan(engine,requested);
        QString factor=QString::number(requested,'f',2);while(factor.endsWith('0'))factor.chop(1);if(factor.endsWith('.'))factor.chop(1);QString model;if(engine==7)model=tr("Spatial");else if(engine==8)model=QStringList{tr("Pro"),tr("SE"),tr("No-denoise")}.value(ui->comboBox_Model_RealCUGAN->currentIndex());else if(engine==9)model=QString::fromLatin1(RealESRGANModels[qBound(0,ComboId(ui->comboBox_Model_RealESRGAN),RealESRGANModelCount-1)].name);else model=ui->comboBox_Model_RealsrNCNNVulkan->currentIndex()==0?tr("DF2K JPEG"):tr("DF2K");const QString engineName=engine==7?tr("MetalFX"):engine==8?tr("Real-CUGAN"):engine==9?tr("Real-ESRGAN"):tr("RealSR"),label=tr("%1 %2 · %3×").arg(engineName,model,factor);QStringList passNames;for(int pass:passes)passNames<<tr("%1×").arg(pass);const QString note=passes.size()>1?tr("Preview ran %1 passes (%2) like the real job").arg(passes.size()).arg(passNames.join(tr(" then "))):QString();
        auto finish=[this,serial,before,target,key,label,note,previewDir](const QString &output){if(serial!=wizardPreviewSerial)return;const QImage native(output),after=native.scaled(target,Qt::IgnoreAspectRatio,Qt::SmoothTransformation);wizardPreviewBeforeCache.insert(key,before);wizardPreviewAfterCache.insert(key,after);wizardPreviewLabelCache.insert(key,label);wizardPreviewNoteCache.insert(key,note);wizardPreviewSizeRatio=QFileInfo(output).size()/double(qMax<qint64>(1,QFileInfo(previewDir+"/in.png").size()));Wizard_SetPreviewImages(before,after,label);if(!note.isEmpty())wizardPreviewStatus->setText(note);QDir(previewDir).removeRecursively();wizardPreviewDir.clear();};
        if(passes.isEmpty()){finish(result.inputPath);return;}
        QString program=engine==5?Current_Path+"/realsr-ncnn-vulkan/realsr-ncnn-vulkan_waifu2xEX":W2xNcnnVulkan_Program(engine);if(!QFileInfo::exists(program)){wizardCompare->setError(tr("Preview engine is not installed: %1").arg(QFileInfo(program).fileName()));QDir(previewDir).removeRecursively();return;}
        using Runner=std::function<void(int,const QString &,int)>;auto runner=std::make_shared<Runner>();std::weak_ptr<Runner> weak=runner;
        *runner=[this,weak,serial,engine,passes,result,program,previewDir,finish](int index,const QString &input,int cumulative){
            const int pass=passes[index],nextFactor=cumulative*pass;const QString output=previewDir+QString("/pass-%1.png").arg(index+1);QStringList args={"-i",input,"-o",output};if(engine==7)args+={"-s",QString::number(pass),"-f","png"};else if(engine==8)args+=QProcess::splitCommand(W2xNcnnVulkan_ScaleNoiseArgs(8,pass,ui->spinBox_DenoiseLevel_image->value())+RealCUGAN_ReadSettings(1));else if(engine==9)args+=QProcess::splitCommand(W2xNcnnVulkan_ScaleNoiseArgs(9,pass,0)+RealESRGAN_ReadSettings(1));else args+=QProcess::splitCommand(" -s 4 "+Realsr_NCNN_Vulkan_ReadSettings());
            wizardPreviewProcess=new QProcess(this);QProcess *process=wizardPreviewProcess;process->setWorkingDirectory(QFileInfo(program).absolutePath());auto keep=weak.lock();connect(process,&QProcess::finished,this,[this,process,keep,serial,index,passes,result,output,nextFactor,previewDir,finish](int code,QProcess::ExitStatus status){const QString message=QString::fromUtf8(process->readAllStandardError()).trimmed();if(wizardPreviewProcess==process)wizardPreviewProcess=nullptr;process->deleteLater();if(serial!=wizardPreviewSerial)return;const QImage after(output);const QSize expected(result.crop.width()*nextFactor,result.crop.height()*nextFactor);if(code||status!=QProcess::NormalExit||message.contains("failed",Qt::CaseInsensitive)||after.isNull()||after.size()!=expected){QString error=message.left(240);if(error.isEmpty()&&after.size()!=expected)error=tr("Preview engine returned %1 × %2; expected %3 × %4.").arg(after.width()).arg(after.height()).arg(expected.width()).arg(expected.height());if(error.isEmpty())error=tr("The preview engine did not produce an image.");wizardCompare->setError(error);QDir(previewDir).removeRecursively();wizardPreviewDir.clear();return;}if(index+1<passes.size())(*keep)(index+1,output,nextFactor);else finish(output);});connect(process,&QProcess::errorOccurred,this,[this,process,serial,previewDir](QProcess::ProcessError error){if(error!=QProcess::FailedToStart||serial!=wizardPreviewSerial)return;if(wizardPreviewProcess==process)wizardPreviewProcess=nullptr;wizardCompare->setError(tr("Could not start %1.").arg(QFileInfo(process->program()).fileName()));process->deleteLater();QDir(previewDir).removeRecursively();wizardPreviewDir.clear();});wizardPreviewStatus->setText(tr("Running preview pass %1 of %2…").arg(index+1).arg(passes.size()));process->start(program,args);
        };(*runner)(0,result.inputPath,1);
    });
    watcher->setFuture(QtConcurrent::run([source,type,tools,previewDir]{PreviewSource result;QImage image;QString decodeError;if(type==2){QProcess ffmpeg;ffmpeg.start(tools+"/ffmpeg_waifu2xEX",{"-v","error","-i",source,"-frames:v","1","-f","image2pipe","-vcodec","png","-"});if(!ffmpeg.waitForFinished(30000)){ffmpeg.kill();ffmpeg.waitForFinished();result.error=QObject::tr("Timed out reading the first video frame.");return result;}image.loadFromData(ffmpeg.readAllStandardOutput(),"PNG");decodeError=QString::fromUtf8(ffmpeg.readAllStandardError()).trimmed();}else{QImageReader reader(source);reader.setAutoTransform(true);image=reader.read();decodeError=reader.errorString();}if(image.isNull()){result.error=decodeError.isEmpty()?QObject::tr("Unable to decode the first file."):QObject::tr("Unable to decode the first file: %1").arg(decodeError);return result;}result.sourceSize=image.size();const int side=qMin({192,image.width(),image.height()});result.crop=image.copy((image.width()-side)/2,(image.height()-side)/2,side,side).convertToFormat(QImage::Format_RGBA8888);result.inputPath=previewDir+"/in.png";if(!result.crop.save(result.inputPath,"PNG"))result.error=QObject::tr("Unable to save the preview crop.");return result;}));
}

void MainWindow::Wizard_SetRunning(bool running)
{
    if(running)wizardRunStartedMs=QDateTime::currentMSecsSinceEpoch();
    for(QPushButton *button:wizardStepButtons)static_cast<StepButton*>(button)->setRunning(running&&button==wizardStepButtons.value(wizardCurrentStep));
    if(!wizardRoot||wizardCurrentStep!=3)return;wizardRunning=running;wizardSummaryCard->setVisible(!running);wizardRunArea->setVisible(running);wizardDoneArea->hide();wizardBackButton->setEnabled(!running);wizardBackButton->setToolTip(running?tr("Back is unavailable while upscaling."):QString());for(QPushButton *b:wizardStepButtons)b->setEnabled(!running);if(running){auto *row=wizardRunArea->findChild<QWidget*>("runStatusRow");if(wizardFilesArea->parentWidget()!=row){wizardFilesArea->setParent(row);qobject_cast<QHBoxLayout*>(row->layout())->addWidget(wizardFilesArea,1);}ui->label_TimeCost->setText(tr("—"));ui->label_TimeRemain->setText(tr("—"));if(wizardDetailsButton)wizardDetailsButton->setChecked(QSettings().value("wizard/showDetails",false).toBool());if(QSettings().value("wizard/keepAwake",true).toBool()&&!wizardCaffeinate){wizardCaffeinate=new QProcess(this);connect(wizardCaffeinate,qOverload<int,QProcess::ExitStatus>(&QProcess::finished),this,[this]{if(wizardCaffeinate){wizardCaffeinate->deleteLater();wizardCaffeinate=nullptr;}});wizardCaffeinate->start("/usr/bin/caffeinate",{"-di"});}}else if(wizardCaffeinate)wizardCaffeinate->terminate();Wizard_Refresh();
}

void MainWindow::Wizard_SetDone()
{
    QTimer::singleShot(0,this,&MainWindow::Wizard_PopulateDoneGallery);QTimer::singleShot(0,this,&MainWindow::Wizard_Refresh);
    if(!wizardRoot||!wizardRunning)return;if(wizardCaffeinate)wizardCaffeinate->terminate();wizardRunning=false;wizardSummaryCard->hide();ui->pushButton_Start->hide();wizardRunArea->hide();wizardDoneArea->show();int total=0,failed=0;QString firstSource,output;const QString outputFolder=ui->checkBox_OutPath_isEnabled->isChecked()?ui->lineEdit_outputPath->text():QString();for(QStandardItemModel *model:{Table_model_image,Table_model_gif,Table_model_video}){total+=model->rowCount();for(int row=0;row<model->rowCount();++row){const QString source=model->index(row,2).data().toString(),candidate=firstOutputFile(source,outputFolder);if(firstSource.isEmpty())firstSource=source;const bool missing=candidate.isEmpty()||!QFileInfo(candidate).isFile()||QFileInfo(candidate).size()<=0;if(model->index(row,1).data().toString().contains("Failed",Qt::CaseInsensitive)||missing){++failed;if(missing)model->setData(model->index(row,1),tr("Failed: No output was created"));}else if(output.isEmpty())output=candidate;}}const bool errors=failed>0;wizardDoneMark->setText(errors?"!":QString::fromUtf8("✓"));wizardDoneTitle->setText(errors?tr("Finished with errors"):tr("All done"));const int upscaled=qMax(0,total-failed);const QString upscaledText=upscaled==1?tr("1 file upscaled"):tr("%1 files upscaled").arg(upscaled);wizardDoneSubtitle->setText(errors?tr("%1 · %2 failed").arg(upscaledText).arg(failed):upscaledText);const QString folder=outputFolder.isEmpty()?QFileInfo(output.isEmpty()?firstSource:output).absolutePath():outputFolder;wizardDoneArea->setProperty("firstOutputPath",output);wizardDoneArea->setProperty("outputFolder",folder);QString summary=tr("Completed in %1\n%2").arg(ui->label_TimeCost->text(),QDir::toNativeSeparators(folder));const QString reason=failureLogTail(ui->textBrowser->toPlainText());if(errors&&!reason.isEmpty())summary+=tr("\nLast error: %1").arg(reason);wizardDoneSummary->setText(summary);wizardBackButton->setEnabled(true);wizardBackButton->setToolTip(QString());for(int i=0;i<wizardStepButtons.size();++i)wizardStepButtons[i]->setEnabled(i<=wizardCurrentStep);
}

void MainWindow::Wizard_PopulateDoneGallery() {
  if (!wizardDoneGallery)
    return;
  auto *gallery = qobject_cast<QVBoxLayout *>(wizardDoneGallery->layout());
  while (QLayoutItem *item = gallery->takeAt(0)) {
    if (item->widget())
      item->widget()->deleteLater();
    delete item;
  }
  const QString outputFolder = ui->checkBox_OutPath_isEnabled->isChecked()
                                   ? ui->lineEdit_outputPath->text()
                                   : QString();
  int total = 0, failed = 0;
  double outputMegapixels = 0;
  QDir thumbs(Data_Path + "/Thumbs");
  thumbs.mkpath(".");
  auto addThumb = [this](QLabel *label, const QString &path,
                         const QSize &size) {
    QPixmap pix;
    if (!path.isEmpty())
      pix = wizardThumbnailCache.value(wizardThumbnailKeys.value(path));
    if (pix.isNull())
      pix = svgPixmap(":/wizard/icons/wizard/image.svg",
                      wizardRoot->palette().color(QPalette::PlaceholderText),
                      QSize(54, 54));
    label->setAlignment(Qt::AlignCenter);
    label->setScaledContents(false);
    label->setPixmap(
        pix.scaled(size, Qt::KeepAspectRatio, Qt::SmoothTransformation));
  };
  const QList<QStandardItemModel *> models =
      {Table_model_image, Table_model_gif, Table_model_video};
  for (int type = 0; type < models.size(); ++type) {
    QStandardItemModel *model = models[type];
    for (int row = 0; row < model->rowCount(); ++row) {
      ++total;
      const QString source = model->index(row, 2).data().toString(),
                    status = model->index(row, 1).data().toString();
      const QString foundOutput = firstOutputFile(source, outputFolder);
      const bool missingOutput = foundOutput.isEmpty() || !QFileInfo(foundOutput).isFile() || QFileInfo(foundOutput).size() <= 0;
      const bool isFailed = status.contains("Failed", Qt::CaseInsensitive) || missingOutput;
      if (isFailed)
        ++failed;
      const QString output = isFailed ? QString() : foundOutput;
      auto *card = new QWidget(wizardDoneGallery);
      card->setObjectName("resultCard");
      card->setProperty("failed", isFailed);
      auto *layout = new QHBoxLayout(card);
      layout->setContentsMargins(14, 12, 14, 12);
      layout->setSpacing(12);
      auto *before = new QLabel(card);
      before->setFixedSize(90, 72);
      before->setAlignment(Qt::AlignCenter);
      addThumb(before, source, before->size());
      layout->addWidget(before);
      auto *arrow = new QLabel(card);
      arrow->setPixmap(svgPixmap(
          isFailed ? ":/wizard/icons/wizard/warning.svg"
                   : ":/wizard/icons/wizard/arrow-right.svg",
          isFailed ? QColor("#FF453A") : QColor("#0A84FF"), QSize(24, 24)));
      layout->addWidget(arrow);
      auto *after = new QLabel(card);
      after->setFixedSize(90, 72);
      after->setAlignment(Qt::AlignCenter);
      addThumb(after, output.isEmpty() ? source : output, after->size());
      layout->addWidget(after);
      auto *details = new QVBoxLayout;
      auto *name = new QLabel(
          QFileInfo(output.isEmpty() ? source : output).fileName(), card);
      name->setObjectName("cardTitle");
      name->setWordWrap(true);
      details->addWidget(name);
      const QSize input =
          wizardMediaSizeCache.value(wizardMediaSizeKeys.value(source));
      const QString outputKey = mediaCacheKey(output);
      const QSize outSize = wizardMediaSizeCache.value(outputKey);
      if (outSize.isValid())
        outputMegapixels += outSize.width() * outSize.height() / 1000000.0;
      const QString dimensions = input.isValid() && outSize.isValid()
                                     ? tr("%1 × %2 → %3 × %4")
                                           .arg(input.width())
                                           .arg(input.height())
                                           .arg(outSize.width())
                                           .arg(outSize.height())
                                     : tr("Result saved");
      const qint64 inBytes = QFileInfo(source).size(),
                   outBytes = QFileInfo(output).size();
      auto *meta = new QLabel(
          missingOutput
              ? tr("No output was created")
              : isFailed
              ? (status.contains(':')
                     ? status
                     : failureLogTail(ui->textBrowser->toPlainText()))
              : dimensions + tr(" · %1 → %2")
                                 .arg(formattedResultSize(inBytes),
                                      formattedResultSize(outBytes)),
          card);
      meta->setObjectName("caption");
      meta->setWordWrap(true);
      details->addWidget(meta);
      auto *buttons = new QHBoxLayout;
      if (isFailed) {
        auto *show = new QPushButton(tr("Show details"), card);
        connect(show, &QPushButton::clicked, this, [this] {
          wizardDoneArea->hide();
          wizardRunArea->show();
          if (wizardDetailsButton)
            wizardDetailsButton->setChecked(true);
        });
        buttons->addWidget(show);
      } else {
        const QString actionPath =
            output.isEmpty() ? QFileInfo(source).absolutePath() : output;
        auto *reveal = new QPushButton(tr("Reveal"), card);
        auto *quick = new QPushButton(tr("Quick Look"), card);
        auto *copy = new QPushButton(tr("Copy path"), card);
        connect(reveal, &QPushButton::clicked, card, [actionPath] {
          if (QFileInfo(actionPath).isFile())
            QProcess::startDetached("/usr/bin/open", {"-R", actionPath});
          else
            QDesktopServices::openUrl(QUrl::fromLocalFile(actionPath));
        });
        connect(quick, &QPushButton::clicked, card, [actionPath] {
          QProcess::startDetached("/usr/bin/qlmanage", {"-p", actionPath});
        });
        connect(copy, &QPushButton::clicked, card, [actionPath] {
          QGuiApplication::clipboard()->setText(
              QDir::toNativeSeparators(actionPath));
        });
        buttons->addWidget(reveal);
        buttons->addWidget(quick);
        buttons->addWidget(copy);
      }
      details->addLayout(buttons);
      layout->addLayout(details, 1);
      gallery->addWidget(card);
      if (!output.isEmpty()) {
        const QString thumbPath = thumbs.filePath(QString::number(qHash(output)) + ".jpg");
        QPointer<QLabel> afterGuard(after), metaGuard(meta);
        auto applyResult = [this,afterGuard,metaGuard,output,outputKey,thumbPath,inBytes,outBytes,type](const MediaResult &result) {
          wizardThumbnailKeys.insert(output,outputKey);wizardMediaSizeKeys.insert(output,outputKey);wizardFileSizeCache.insert(outputKey,result.byteSize);
          wizardDurationCache.insert(outputKey,result.durationSeconds);wizardFrameCountCache.insert(outputKey,result.frameCount);wizardAudioSizeCache.insert(outputKey,result.audioBytes);
          if(result.size.isValid())wizardMediaSizeCache.insert(outputKey,result.size);
          if(!result.image.isNull())wizardThumbnailCache.insert(outputKey,QPixmap::fromImage(result.image));
          const QPixmap pix=wizardThumbnailCache.value(outputKey);if(afterGuard&&!pix.isNull())afterGuard->setPixmap(pix.scaled(afterGuard->size(),Qt::KeepAspectRatio,Qt::SmoothTransformation));
          if(metaGuard)metaGuard->setText((result.size.isValid()?tr("%1 × %2").arg(result.size.width()).arg(result.size.height()):tr("Result saved"))+tr(" · %1 → %2").arg(formattedResultSize(inBytes),formattedResultSize(outBytes)));
          if(!pix.isNull())pix.save(thumbPath,"JPG",82);
          if(inBytes>0&&outBytes>0&&result.size.isValid()){const double megapixels=qint64(result.size.width())*result.size.height()/1000000.0,measured=outBytes/double(inBytes)/megapixels;QSettings().setValue(QString("estimate/%1").arg(QStringList{"image","gif","video"}[type]),measured);}
          QJsonArray history=QJsonDocument::fromJson(QSettings().value("history/items").toByteArray()).array(),updated;updated.append(QJsonObject{{"output",output},{"name",QFileInfo(output).fileName()},{"resolution",result.size.isValid()?QString("%1 × %2").arg(result.size.width()).arg(result.size.height()):tr("Result saved")},{"when",tr("Just now")},{"thumb",pix.isNull()?QString():thumbPath}});for(const QJsonValue &old:history)if(old.toObject().value("output").toString()!=output&&updated.size()<20)updated.append(old);QSettings().setValue("history/items",QJsonDocument(updated).toJson(QJsonDocument::Compact));
        };
        if(wizardThumbnailKeys.value(output)==outputKey){MediaResult cached;cached.cacheKey=outputKey;cached.image=wizardThumbnailCache.value(outputKey).toImage();cached.size=wizardMediaSizeCache.value(outputKey);cached.byteSize=wizardFileSizeCache.value(outputKey,-1);cached.durationSeconds=wizardDurationCache.value(outputKey,-1);cached.frameCount=wizardFrameCountCache.value(outputKey,-1);cached.audioBytes=wizardAudioSizeCache.value(outputKey);applyResult(cached);}else{auto *watcher=new QFutureWatcher<MediaResult>(this);connect(watcher,&QFutureWatcher<MediaResult>::finished,this,[watcher,applyResult]{applyResult(watcher->result());watcher->deleteLater();});const QString toolsPath=Current_Path;watcher->setFuture(QtConcurrent::run([output,type,toolsPath]{return readMedia(output,type,toolsPath);}));}
      }
    }
  }
  const QString elapsed = ui->label_TimeCost->text();
  double elapsedSeconds = 0;
  const QStringList parts = elapsed.split(':');
  if (parts.size() == 2)
    elapsedSeconds = parts[0].toDouble() * 60 + parts[1].toDouble();
  else if (parts.size() == 3)
    elapsedSeconds = parts[0].toDouble() * 3600 + parts[1].toDouble() * 60 +
                     parts[2].toDouble();
  const int success = qMax(0, total - failed);
  QString completion=tr("%1 · Completed in %2").arg(success == 1 ? tr("1 file") : tr("%1 files").arg(success),elapsed);
  if(elapsedSeconds>5)completion+=tr(" · %1 files/min").arg(success/(elapsedSeconds/60.0),0,'f',1);
  wizardDoneSubtitle->setText(completion);
  if (elapsedSeconds > 0 && outputMegapixels > 0)
    QSettings().setValue(
        "bench/" + QString::number(ComboId(ui->comboBox_Engine_Image)),
        elapsedSeconds / outputMegapixels);
  const QJsonArray history=QJsonDocument::fromJson(QSettings().value("history/items").toByteArray()).array();
  QSet<QString> keep;
  for (const QJsonValue &value : history)
    keep.insert(value.toObject().value("thumb").toString());
  for (const QFileInfo &file : thumbs.entryInfoList(QDir::Files))
    if (!keep.contains(file.absoluteFilePath()))
      QFile::remove(file.absoluteFilePath());
}

void MainWindow::Wizard_ShowSettings()
{
    QDialog dialog(this);dialog.setObjectName("wizardRoot");dialog.setWindowTitle(tr("Settings"));dialog.setModal(true);dialog.setMinimumSize(520,680);auto applyDialogTheme=[this,&dialog]{Wizard_ApplyTheme();dialog.setPalette(wizardRoot->palette());dialog.setStyleSheet(wizardRoot->styleSheet());for(QWidget *widget:dialog.findChildren<QWidget*>())widget->setPalette(wizardRoot->palette());};applyDialogTheme();auto *layout=new QVBoxLayout(&dialog);layout->setContentsMargins(22,20,22,18);layout->setSpacing(12);auto *title=new QLabel(tr("Settings"),&dialog);title->setObjectName("pageTitle");layout->addWidget(title);

    QVBoxLayout *engineBox;auto *engineCard=cardWidget(&dialog,&engineBox);auto *engineTitle=new QLabel(tr("Engine check"),engineCard);engineTitle->setObjectName("cardTitle");auto *engineHelp=new QLabel(tr("Verify the tools Waifu2x-Mac uses on this Mac."),engineCard);engineHelp->setObjectName("helper");auto *runCheck=new QPushButton(tr("Run engine check"),engineCard);runCheck->setObjectName("primary");auto *spinner=new QLabel(engineCard);spinner->setObjectName("settingsSpinner");spinner->setAlignment(Qt::AlignCenter);spinner->hide();auto *results=new QLabel(engineCard);results->setWordWrap(true);results->setTextFormat(Qt::RichText);engineBox->addWidget(engineTitle);engineBox->addWidget(engineHelp);engineBox->addWidget(runCheck);engineBox->addWidget(spinner);engineBox->addWidget(results);layout->addWidget(engineCard);
    const QList<QPair<QString,QCheckBox*>> checks={{tr("MetalFX"),ui->checkBox_isCompatible_MetalFX},{tr("Real-CUGAN"),ui->checkBox_isCompatible_RealCUGAN},{tr("Real-ESRGAN"),ui->checkBox_isCompatible_RealESRGAN},{tr("RealSR"),ui->checkBox_isCompatible_Realsr_NCNN_Vulkan},{tr("RIFE"),ui->checkBox_isCompatible_RifeNcnnVulkan},{tr("FFmpeg"),ui->checkBox_isCompatible_FFmpeg},{tr("ImageMagick"),ui->checkBox_isCompatible_ImageMagick},{tr("Gifsicle"),ui->checkBox_isCompatible_Gifsicle}};auto showResults=[checks,results]{QStringList lines;for(const auto &check:checks){const QString color=check.second->isChecked()?QStringLiteral("#248A3D"):QStringLiteral("#D70015");lines<<QString("<span style='color:%1;font-weight:600'>%2 %3</span>").arg(color,check.second->isChecked()?QString::fromUtf8("✓"):QString::fromUtf8("✗"),check.first.toHtmlEscaped());}results->setText(lines.join("<br>"));};QStringList pendingResults;const QString pendingColor=results->palette().color(QPalette::PlaceholderText).name(),pendingText=tr("Not checked yet");for(const auto &check:checks)pendingResults<<QString("<span style='color:%1;font-weight:600'>- %2 — %3</span>").arg(pendingColor,check.first.toHtmlEscaped(),pendingText.toHtmlEscaped());results->setText(pendingResults.join("<br>"));auto *spinTimer=new QTimer(&dialog);spinTimer->setInterval(250);connect(spinTimer,&QTimer::timeout,spinner,[spinner]{static int frame=0;spinner->setText(QObject::tr("Checking engines%1").arg(QString((frame++%3)+1,QChar('.'))));});connect(runCheck,&QPushButton::clicked,this,[this,runCheck,spinner,spinTimer]{runCheck->setEnabled(false);spinner->show();spinTimer->start();on_pushButton_compatibilityTest_clicked();});connect(this,&MainWindow::Send_Waifu2x_Compatibility_Test_finished,&dialog,[runCheck,spinner,spinTimer,showResults]{spinTimer->stop();spinner->hide();runCheck->setEnabled(true);showResults();});

    QVBoxLayout *appearanceBox;auto *appearanceCard=cardWidget(&dialog,&appearanceBox);auto *appearanceTitle=new QLabel(tr("Appearance"),appearanceCard);appearanceTitle->setObjectName("cardTitle");appearanceBox->addWidget(appearanceTitle);auto *appearanceRow=new QHBoxLayout;auto *appearanceGroup=new QButtonGroup(&dialog);appearanceGroup->setExclusive(true);const QString currentAppearance=QSettings().value("appearance","system").toString();const QStringList appearanceIds={"system","light","dark"};const QStringList appearanceNames={tr("System"),tr("Light"),tr("Dark")};for(int i=0;i<appearanceIds.size();++i){auto *button=segmentButton(appearanceNames[i],appearanceCard);button->setProperty("appearanceId",appearanceIds[i]);button->setChecked(appearanceIds[i]==currentAppearance);appearanceGroup->addButton(button,i);appearanceRow->addWidget(button);}appearanceBox->addLayout(appearanceRow);layout->addWidget(appearanceCard);connect(appearanceGroup,&QButtonGroup::idClicked,&dialog,[appearanceIds,applyDialogTheme](int id){QSettings().setValue("appearance",appearanceIds[id]);applyDialogTheme();});

    QVBoxLayout *aboutBox;auto *aboutCard=cardWidget(&dialog,&aboutBox);auto *aboutTitle=new QLabel(tr("Waifu2x-Mac %1").arg(QStringLiteral(APP_VERSION)),aboutCard);aboutTitle->setObjectName("cardTitle");auto *licenses=new QPushButton(tr("Licenses and credits"),aboutCard);licenses->setObjectName("detailsButton");auto *reset=new QPushButton(tr("Reset to defaults"),aboutCard);auto *aboutRow=new QHBoxLayout;aboutRow->addWidget(new AppMark(aboutCard,48));aboutTitle->setWordWrap(true);aboutRow->addWidget(aboutTitle,1);aboutBox->addLayout(aboutRow);aboutBox->addWidget(licenses);aboutBox->addWidget(reset);layout->addWidget(aboutCard);connect(licenses,&QPushButton::clicked,&dialog,[this,&dialog]{QFile notice(":/wizard/NOTICE.md");static_cast<void>(notice.open(QIODevice::ReadOnly|QIODevice::Text));QDialog licensesDialog(&dialog);licensesDialog.setObjectName("wizardRoot");licensesDialog.setWindowTitle(tr("Licenses and credits"));licensesDialog.resize(620,420);licensesDialog.setPalette(wizardRoot->palette());licensesDialog.setStyleSheet(wizardRoot->styleSheet());auto *box=new QVBoxLayout(&licensesDialog);auto *text=new QTextBrowser(&licensesDialog);text->setPlainText(QString::fromUtf8(notice.readAll()));box->addWidget(text);auto *close=new QDialogButtonBox(QDialogButtonBox::Close,&licensesDialog);connect(close,&QDialogButtonBox::rejected,&licensesDialog,&QDialog::accept);box->addWidget(close);licensesDialog.exec();});connect(reset,&QPushButton::clicked,&dialog,[this,&dialog,applyDialogTheme]{QMessageBox confirm(QMessageBox::Question,tr("Reset to defaults"),tr("Reset all settings to their defaults?"),QMessageBox::Yes|QMessageBox::No,&dialog);confirm.setPalette(wizardRoot->palette());confirm.setStyleSheet(wizardRoot->styleSheet());if(confirm.exec()!=QMessageBox::Yes)return;QFile::remove(Data_Path+"/settings.ini");QSettings().clear();Settings_isReseted=true;applyDialogTheme();QMessageBox done(QMessageBox::Information,tr("Settings"),tr("Defaults restored. Restart Waifu2x-Mac to apply all changes."),QMessageBox::Ok,&dialog);done.setPalette(wizardRoot->palette());done.setStyleSheet(wizardRoot->styleSheet());done.exec();});
    layout->addStretch();auto *buttons=new QDialogButtonBox(QDialogButtonBox::Close,&dialog);connect(buttons,&QDialogButtonBox::rejected,&dialog,&QDialog::accept);layout->addWidget(buttons);dialog.exec();
}

void MainWindow::Wizard_ShowAdvanced(int page)
{
    if(!wizardAdvancedDialog)
    {
        auto *dialog=new WizardAdvancedDialog(this);wizardAdvancedDialog=dialog;wizardAdvancedTabs=dialog->tabs;wizardAdvancedPages=dialog->pages;
        auto addRow=[this](QVBoxLayout *pageLayout,const QString &title,const QString &help,QWidget *control,const QString &pill=QString()){
            QVBoxLayout *box;auto *row=cardWidget(wizardAdvancedDialog,&box);auto *top=new QHBoxLayout;auto *label=new QLabel(title,row);label->setObjectName("cardTitle");top->addWidget(label);if(!pill.isEmpty()){auto *tag=new QLabel(pill,row);tag->setObjectName("pill");top->addWidget(tag);}top->addStretch();const bool textInput=qobject_cast<QLineEdit *>(control);if(control&&!textInput){control->setMaximumWidth(220);top->addWidget(control);}box->addLayout(top);if(textInput){control->setMinimumHeight(36);control->setMaximumWidth(QWIDGETSIZE_MAX);box->addWidget(control);}if(!help.isEmpty()){auto *caption=new QLabel(help,row);caption->setObjectName("helper");caption->setWordWrap(true);box->addWidget(caption);}pageLayout->insertWidget(pageLayout->count()-1,row);return row;
        };
        auto mirrorCheck=[this](QCheckBox *source){auto *check=new QCheckBox(wizardAdvancedDialog);check->setChecked(source->isChecked());connect(check,&QCheckBox::toggled,source,&QCheckBox::setChecked);connect(source,&QCheckBox::toggled,check,[check](bool on){QSignalBlocker b(check);check->setChecked(on);});connect(check,&QCheckBox::toggled,this,[this]{Wizard_Refresh();});return check;};
        auto mirrorSpin=[this](QSpinBox *source){auto *spin=new QSpinBox(wizardAdvancedDialog);spin->setRange(source->minimum(),source->maximum());spin->setValue(source->value());connect(spin,qOverload<int>(&QSpinBox::valueChanged),source,&QSpinBox::setValue);connect(source,qOverload<int>(&QSpinBox::valueChanged),spin,[spin](int value){QSignalBlocker b(spin);spin->setValue(value);});connect(spin,qOverload<int>(&QSpinBox::valueChanged),this,[this]{Wizard_Refresh();});return spin;};

        auto *enginePage=dialog->addPage(tr("Engine"),":/wizard/icons/wizard/sliders.svg");
        wizardAdvancedTile=new QComboBox(dialog);for(const auto &entry:QList<QPair<QString,int>>{{tr("Auto"),0},{QStringLiteral("64"),64},{QStringLiteral("128"),128},{QStringLiteral("256"),256},{QStringLiteral("384"),384},{QStringLiteral("512"),512}})wizardAdvancedTile->addItem(entry.first,entry.second);wizardAdvancedTileRow=addRow(enginePage,tr("Tile size"),tr("Smaller tiles use less memory."),wizardAdvancedTile,tr("Selected engine"));wizardAdvancedTileRow->setProperty("engines","5,8,9");
        wizardAdvancedGpu=new QComboBox(dialog);wizardAdvancedGpu->addItem(tr("Automatic"),-2);for(int i=0;i<=16;++i)wizardAdvancedGpu->addItem(tr("GPU %1").arg(i),i);wizardAdvancedGpuRow=addRow(enginePage,tr("GPU"),tr("Automatic uses the best available device."),wizardAdvancedGpu,tr("Selected engine"));wizardAdvancedGpuRow->setProperty("engines","5,8,9");
        auto *tta=new QCheckBox(dialog);wizardAdvancedTta=tta;wizardAdvancedTtaRow=addRow(enginePage,tr("TTA mode"),tr("Higher quality, about eight times slower."),tta,tr("Selected engine"));wizardAdvancedTtaRow->setProperty("engines","5,8,9");
        auto *threads=new QComboBox(dialog);threads->setObjectName("advancedThreads");threads->addItems({tr("Low memory"),tr("Balanced"),tr("Fast")});threads->setCurrentIndex(ui->spinBox_ThreadNum_image->value()<=1?0:ui->spinBox_ThreadNum_image->value()>=4?2:1);wizardAdvancedThreadsRow=addRow(enginePage,tr("Load / process / save threads"),tr("Sets the existing parallel worker controls."),threads);wizardAdvancedThreadsRow->setProperty("engines","5,8,9");
        auto *cuganModel=mirrorCombo(ui->comboBox_Model_RealCUGAN,dialog);auto *cuganModelRow=addRow(enginePage,tr("Model"),tr("Pro, SE, or no-denoise model."),cuganModel,tr("Real-CUGAN"));cuganModelRow->setProperty("engines","8");
        auto *syncGap=mirrorCombo(ui->comboBox_SyncGap_RealCUGAN,dialog);auto *syncRow=addRow(enginePage,tr("Sync gap"),tr("Controls Real-CUGAN synchronization."),syncGap,tr("Real-CUGAN"));syncRow->setProperty("engines","8");
        auto *esrModel=mirrorCombo(ui->comboBox_Model_RealESRGAN,dialog);auto *esrRow=addRow(enginePage,tr("Model"),tr("All installed Real-ESRGAN models."),esrModel,tr("Real-ESRGAN"));esrRow->setProperty("engines","9");
        auto *srModel=mirrorCombo(ui->comboBox_Model_RealsrNCNNVulkan,dialog);auto *srRow=addRow(enginePage,tr("Model"),tr("Choose the RealSR source model."),srModel,tr("RealSR"));srRow->setProperty("engines","5");
        wizardAdvancedMetalInfo=addRow(enginePage,tr("MetalFX"),tr("MetalFX runs on Apple's spatial scaler and has no tuning options"),nullptr);wizardAdvancedMetalInfo->setProperty("engines","7");
        connect(wizardAdvancedTile,qOverload<int>(&QComboBox::currentIndexChanged),this,[this](int){int engine=ComboId(ui->comboBox_Engine_Image),value=wizardAdvancedTile->currentData().toInt();if(engine==8)ui->spinBox_TileSize_RealCUGAN->setValue(value);else if(engine==9)ui->spinBox_TileSize_RealESRGAN->setValue(value);else if(engine==5)ui->spinBox_TileSize_RealsrNCNNVulkan->setValue(value);Wizard_Refresh();});
        connect(wizardAdvancedGpu,qOverload<int>(&QComboBox::currentIndexChanged),this,[this](int){int engine=ComboId(ui->comboBox_Engine_Image),value=wizardAdvancedGpu->currentData().toInt();if(engine==8)ui->spinBox_GPUID_RealCUGAN->setValue(value);else if(engine==9)ui->spinBox_GPUID_RealESRGAN->setValue(value);else if(engine==5){int index=ui->comboBox_GPUID_RealsrNCNNVulkan->findText(value<0?QStringLiteral("auto"):QString::number(value));if(index>=0)ui->comboBox_GPUID_RealsrNCNNVulkan->setCurrentIndex(index);}Wizard_Refresh();});
        connect(wizardAdvancedTta,&QAbstractButton::toggled,this,[this](bool on){int engine=ComboId(ui->comboBox_Engine_Image);if(engine==8)ui->checkBox_TTA_RealCUGAN->setChecked(on);else if(engine==9)ui->checkBox_TTA_RealESRGAN->setChecked(on);else if(engine==5)ui->checkBox_TTA_RealsrNCNNVulkan->setChecked(on);Wizard_Refresh();});
        connect(threads,qOverload<int>(&QComboBox::currentIndexChanged),this,[this](int index){const int value=index==0?1:index==1?2:4;ui->spinBox_ThreadNum_image->setValue(value);ui->spinBox_ThreadNum_gif_internal->setValue(value);ui->spinBox_ThreadNum_video_internal->setValue(value);Wizard_Refresh();});

        auto *outputPage=dialog->addPage(tr("Output"),":/wizard/icons/wizard/folder.svg");
        auto *destination=new QComboBox(dialog);destination->addItems({tr("Original folder"),tr("Custom folder")});destination->setCurrentIndex(ui->checkBox_OutPath_isEnabled->isChecked()?1:0);addRow(outputPage,tr("Save to"),tr("Choose a custom folder below when enabled."),destination);
        auto *folder=new QPushButton(tr("Choose folder…"),dialog);addRow(outputPage,tr("Custom folder"),QDir::toNativeSeparators(ui->lineEdit_outputPath->text()),folder);connect(destination,qOverload<int>(&QComboBox::currentIndexChanged),this,[this](int index){ui->checkBox_OutPath_isEnabled->setChecked(index==1);Wizard_Refresh();});connect(folder,&QPushButton::clicked,this,[this]{const QString path=QFileDialog::getExistingDirectory(this,tr("Choose output folder"),ui->lineEdit_outputPath->text());if(!path.isEmpty()){ui->lineEdit_outputPath->setText(path);ui->checkBox_OutPath_isEnabled->setChecked(true);Wizard_Refresh();}});
        auto *nameTemplate=new QLineEdit(wizardNameTemplate,dialog);auto *nameRow=addRow(outputPage,tr("File name template"),tr("Preview: example_realcugan_2x.png"),nameTemplate);nameRow->setObjectName("nameTemplateRow");connect(nameTemplate,&QLineEdit::textChanged,this,[this](const QString &value){if(value.contains("{name}")){wizardNameTemplate=value;QSettings().setValue("wizard/nameTemplate",value);}Wizard_Refresh();});
        addRow(outputPage,tr("Image format"),tr("Format for still-image output."),mirrorCombo(ui->comboBox_ImageSaveFormat,dialog));addRow(outputPage,tr("Image quality"),tr("Compression quality for supported formats."),mirrorSpin(ui->spinBox_ImageQualityLevel));
        addRow(outputPage,tr("Overwrite existing files"),QString(),mirrorCheck(ui->checkBox_OutPath_Overwrite));addRow(outputPage,tr("Keep original file name"),QString(),mirrorCheck(ui->checkBox_OutPath_KeepOriginalFileName));addRow(outputPage,tr("Keep parent folder structure"),QString(),mirrorCheck(ui->checkBox_KeepParentFolder));
        auto dangerous=[this,mirrorCheck,addRow,outputPage](const QString &title,const QString &warning,QCheckBox *source){auto *check=mirrorCheck(source);addRow(outputPage,title,warning,check);connect(check,&QCheckBox::clicked,this,[this,check,source,title](bool on){if(!on)return;QMessageBox confirm(QMessageBox::Warning,title,tr("This changes or removes original files. Continue?"),QMessageBox::Yes|QMessageBox::No,wizardAdvancedDialog);confirm.setPalette(wizardRoot->palette());confirm.setStyleSheet(wizardRoot->styleSheet());if(confirm.exec()!=QMessageBox::Yes){QSignalBlocker b(check);check->setChecked(false);source->setChecked(false);}});};
        dangerous(tr("Delete original after success"),tr("Warning: removes the source after a successful output."),ui->checkBox_DelOriginal);dangerous(tr("Replace original file"),tr("Warning: replaces the source with the processed file."),ui->checkBox_ReplaceOriginalFile);addRow(outputPage,tr("Re-process finished files"),QString(),mirrorCheck(ui->checkBox_ReProcFinFiles));

        auto *videoPage=dialog->addPage(tr("Video"),":/wizard/icons/wizard/motion.svg");
        auto *encoder=new QComboBox(dialog);encoder->setObjectName("advEncoder");encoder->addItem(tr("H.264"),"libx264");encoder->addItem(tr("HEVC"),"libx265");encoder->setCurrentIndex(ui->lineEdit_encoder_vid->text().contains("265")?1:0);addRow(videoPage,tr("Codec"),tr("HEVC adds the Apple-compatible hvc1 tag."),encoder);
        auto *crfControl=new QWidget(dialog);auto *crfBox=new QHBoxLayout(crfControl);crfBox->setContentsMargins(0,0,0,0);auto *crf=new QSlider(Qt::Horizontal,crfControl);crf->setObjectName("advCrf");crf->setRange(14,28);const auto match=QRegularExpression("-crf\\s+(\\d+)").match(ui->lineEdit_ExCommand_output->text());crf->setValue(match.hasMatch()?match.captured(1).toInt():18);auto *crfLabel=new QLabel(crfControl);crfBox->addWidget(crf);crfBox->addWidget(crfLabel);addRow(videoPage,tr("Quality"),tr("14 visually lossless · 18 high · 23 balanced · 28 small"),crfControl);
        auto *preset=new QComboBox(dialog);preset->addItems({tr("Slow"),tr("Medium"),tr("Fast"),tr("Very fast")});const auto presetMatch=QRegularExpression("-preset\\s+(slow|medium|fast|veryfast)").match(ui->lineEdit_ExCommand_output->text());preset->setCurrentIndex(QStringList{"slow","medium","fast","veryfast"}.indexOf(presetMatch.hasMatch()?presetMatch.captured(1):QStringLiteral("medium")));addRow(videoPage,tr("Encoder preset"),tr("Slower presets trade time for compression."),preset);
        auto *pixel=new QComboBox(dialog);pixel->addItems({"yuv420p","yuv422p","yuv444p"});pixel->setCurrentText(ui->lineEdit_pixformat->text().isEmpty()?QStringLiteral("yuv420p"):ui->lineEdit_pixformat->text());addRow(videoPage,tr("Pixel format"),QString(),pixel);
        auto *extra=new QLineEdit(ui->lineEdit_ExCommand_output->text(),dialog);extra->setObjectName("expertFfmpegArgs");extra->setFont(QFontDatabase::systemFont(QFontDatabase::FixedFont));addRow(videoPage,tr("Extra ffmpeg arguments"),tr("Expert. Passed to the existing output command."),extra);
        auto applyVideo=[this,encoder,crf,preset,extra,crfLabel]{QString args=extra->text();args.remove(QRegularExpression("(?:^|\\s)-crf\\s+\\d+"));args.remove(QRegularExpression("(?:^|\\s)-preset\\s+\\S+"));args.remove(QRegularExpression("(?:^|\\s)-tag:v\\s+hvc1"));args=args.simplified();args+=(args.isEmpty()?QString():" ")+QString("-crf %1 -preset %2").arg(crf->value()).arg(QStringList{"slow","medium","fast","veryfast"}.value(preset->currentIndex(),"medium"));if(encoder->currentData().toString()=="libx265")args+=" -tag:v hvc1";ui->groupBox_video_settings->setChecked(true);ui->lineEdit_encoder_vid->setText(encoder->currentData().toString());ui->lineEdit_ExCommand_output->setText(args);{QSignalBlocker b(extra);extra->setText(args);}const int value=crf->value();crfLabel->setText(QString::number(value)+(value<=15?tr(" · Visually lossless"):value<=19?tr(" · High"):value<=24?tr(" · Balanced"):tr(" · Small")));Wizard_Refresh();};connect(encoder,qOverload<int>(&QComboBox::currentIndexChanged),this,[applyVideo](int){applyVideo();});connect(crf,&QSlider::valueChanged,this,[applyVideo](int){applyVideo();});connect(preset,qOverload<int>(&QComboBox::currentIndexChanged),this,[applyVideo](int){applyVideo();});connect(extra,&QLineEdit::editingFinished,this,applyVideo);connect(pixel,&QComboBox::currentTextChanged,ui->lineEdit_pixformat,&QLineEdit::setText);applyVideo();
        addRow(videoPage,tr("Frame interpolation"),tr("Create intermediate frames with RIFE."),mirrorCheck(ui->checkBox_EnableVFI_Home));addRow(videoPage,tr("Multiplier"),tr("2×, 3×, or 4× frames."),mirrorSpin(ui->spinBox_MultipleOfFPS_VFI));addRow(videoPage,tr("RIFE model"),QString(),mirrorCombo(ui->comboBox_Model_VFI,dialog));addRow(videoPage,tr("UHD mode"),QString(),mirrorCheck(ui->checkBox_UHD_VFI));addRow(videoPage,tr("RIFE GPU"),QString(),mirrorCombo(ui->comboBox_GPUID_VFI,dialog));addRow(videoPage,tr("RIFE TTA"),QString(),mirrorCheck(ui->checkBox_TTA_VFI));

        auto *gifPage=dialog->addPage(tr("GIF & images"),":/wizard/icons/wizard/gif.svg");addRow(gifPage,tr("Optimize GIF"),tr("Run gifsicle after processing."),mirrorCheck(ui->checkBox_OptGIF));addRow(gifPage,tr("Image format"),tr("Uses the same image format setting as Output."),mirrorCombo(ui->comboBox_ImageSaveFormat,dialog));addRow(gifPage,tr("Skip images already larger than target"),tr("Applies when Target size is enabled."),mirrorCheck(ui->checkBox_AutoSkip_CustomRes));

        auto *systemPage=dialog->addPage(tr("System"),":/wizard/icons/wizard/settings.svg");addRow(systemPage,tr("When finished"),tr("Do nothing, open folder, sleep, shut down, and other existing actions."),mirrorCombo(ui->comboBox_FinishAction,dialog));addRow(systemPage,tr("Notification sound"),QString(),mirrorCheck(ui->checkBox_NfSound));wizardParallelFiles=mirrorSpin(ui->spinBox_ThreadNum_image);wizardParallelFiles->setRange(1,qMin(16,ui->spinBox_ThreadNum_image->maximum()));addRow(systemPage,tr("Parallel files"),tr("Also sets GIF and video worker counts."),wizardParallelFiles);connect(wizardParallelFiles,qOverload<int>(&QSpinBox::valueChanged),ui->spinBox_ThreadNum_gif_internal,&QSpinBox::setValue);connect(wizardParallelFiles,qOverload<int>(&QSpinBox::valueChanged),ui->spinBox_ThreadNum_video_internal,&QSpinBox::setValue);
        auto *awake=new QCheckBox(dialog);awake->setChecked(QSettings().value("wizard/keepAwake",true).toBool());addRow(systemPage,tr("Keep screen awake while processing"),tr("Uses macOS caffeinate only while a job is active."),awake);connect(awake,&QCheckBox::toggled,this,[](bool on){QSettings().setValue("wizard/keepAwake",on);});auto *showDetails=new QCheckBox(dialog);showDetails->setChecked(QSettings().value("wizard/showDetails",false).toBool());addRow(systemPage,tr("Show details log by default"),QString(),showDetails);connect(showDetails,&QCheckBox::toggled,this,[](bool on){QSettings().setValue("wizard/showDetails",on);});

        for(QComboBox *combo:dialog->findChildren<QComboBox*>())fitComboPopup(combo);

        connect(dialog->restore,&QPushButton::clicked,this,[this,dialog]{QMessageBox confirm(QMessageBox::Question,tr("Restore defaults"),tr("Restore defaults for this page?"),QMessageBox::Yes|QMessageBox::No,dialog);confirm.setPalette(wizardRoot->palette());confirm.setStyleSheet(wizardRoot->styleSheet());if(confirm.exec()!=QMessageBox::Yes)return;switch(dialog->tabs->checkedId()){case 0:if(wizardAdvancedTile)wizardAdvancedTile->setCurrentIndex(0);if(wizardAdvancedGpu)wizardAdvancedGpu->setCurrentIndex(0);if(wizardAdvancedTta)wizardAdvancedTta->setChecked(false);break;case 1:ui->checkBox_OutPath_Overwrite->setChecked(false);ui->checkBox_OutPath_KeepOriginalFileName->setChecked(false);ui->checkBox_KeepParentFolder->setChecked(false);ui->checkBox_DelOriginal->setChecked(false);ui->checkBox_ReplaceOriginalFile->setChecked(false);ui->checkBox_ReProcFinFiles->setChecked(false);break;case 2:ui->lineEdit_encoder_vid->setText("libx264");ui->lineEdit_pixformat->setText("yuv420p");ui->lineEdit_ExCommand_output->setText("-crf 18");ui->checkBox_EnableVFI_Home->setChecked(false);break;case 3:ui->checkBox_OptGIF->setChecked(false);ui->checkBox_AutoSkip_CustomRes->setChecked(true);break;case 4:ui->comboBox_FinishAction->setCurrentIndex(0);ui->checkBox_NfSound->setChecked(true);ui->spinBox_ThreadNum_image->setValue(2);ui->spinBox_ThreadNum_gif_internal->setValue(2);ui->spinBox_ThreadNum_video_internal->setValue(2);QSettings().setValue("wizard/keepAwake",true);QSettings().setValue("wizard/showDetails",false);break;}Wizard_Refresh();});
    }
    int engine=ComboId(ui->comboBox_Engine_Image),tile=0,gpu=-2;bool tta=false;if(engine==8){tile=ui->spinBox_TileSize_RealCUGAN->value();gpu=ui->spinBox_GPUID_RealCUGAN->value();tta=ui->checkBox_TTA_RealCUGAN->isChecked();}else if(engine==9){tile=ui->spinBox_TileSize_RealESRGAN->value();gpu=ui->spinBox_GPUID_RealESRGAN->value();tta=ui->checkBox_TTA_RealESRGAN->isChecked();}else if(engine==5){tile=ui->spinBox_TileSize_RealsrNCNNVulkan->value();gpu=ui->comboBox_GPUID_RealsrNCNNVulkan->currentText()=="auto"?-2:ui->comboBox_GPUID_RealsrNCNNVulkan->currentText().toInt();tta=ui->checkBox_TTA_RealsrNCNNVulkan->isChecked();}if(wizardAdvancedTile){QSignalBlocker b(wizardAdvancedTile);wizardAdvancedTile->setCurrentIndex(qMax(0,wizardAdvancedTile->findData(tile)));}if(wizardAdvancedGpu){QSignalBlocker b(wizardAdvancedGpu);wizardAdvancedGpu->setCurrentIndex(qMax(0,wizardAdvancedGpu->findData(gpu)));}if(wizardAdvancedTta){QSignalBlocker b(wizardAdvancedTta);wizardAdvancedTta->setChecked(tta);}for(QWidget *row:wizardAdvancedDialog->findChildren<QWidget*>()){const QString engines=row->property("engines").toString();if(!engines.isEmpty())row->setVisible(engines.split(',').contains(QString::number(engine)));}wizardAdvancedDialog->setPalette(wizardRoot->palette());wizardAdvancedDialog->setStyleSheet(wizardRoot->styleSheet());for(QWidget *widget:wizardAdvancedDialog->findChildren<QWidget*>())widget->setPalette(wizardRoot->palette());for(QComboBox *combo:wizardAdvancedDialog->findChildren<QComboBox*>())fitComboPopup(combo);static_cast<WizardAdvancedDialog *>(wizardAdvancedDialog)->setPage(page);wizardAdvancedDialog->exec();Wizard_Refresh();
}

#include "wizard.moc"
