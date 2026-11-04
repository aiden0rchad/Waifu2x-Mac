#include "wizard_preview.h"

#include <QMouseEvent>
#include <QPainter>
#include <QTimer>

CompareSlider::CompareSlider(QWidget *parent):QSlider(Qt::Horizontal,parent)
{
    setRange(0,100);setValue(50);setMinimumSize(0,340);setSizePolicy(QSizePolicy::Ignored,QSizePolicy::MinimumExpanding);setFocusPolicy(Qt::StrongFocus);setAccessibleName(tr("Before and after comparison"));setAccessibleDescription(tr("Use Left and Right arrow keys to move the comparison handle."));m_shimmer=new QTimer(this);m_shimmer->setInterval(24);connect(m_shimmer,&QTimer::timeout,this,[this]{m_phase=(m_phase+7)%240;update();});
}

void CompareSlider::setImages(const QImage &before,const QImage &after,const QString &afterLabel){m_before=before;m_after=after;m_afterLabel=afterLabel;m_error.clear();setProperty("previewError",QVariant());setLoading(false);setProperty("previewComplete",true);update();}
void CompareSlider::setLoading(bool loading){m_loading=loading;m_error.clear();if(loading){setProperty("previewComplete",false);setProperty("previewError",QVariant());}if(loading&&!qEnvironmentVariableIsSet("W2X_SNAPSHOT_DIR"))m_shimmer->start();else m_shimmer->stop();update();}
void CompareSlider::setError(const QString &message){m_error=message;setProperty("previewError",message);setLoading(false);setProperty("previewComplete",true);update();}
void CompareSlider::setZoom(int zoom){m_zoom=qBound(1,zoom,2);update();}
void CompareSlider::setFromX(qreal x){setValue(qBound(0,qRound(100*x/qMax(1,width())),100));}
void CompareSlider::mousePressEvent(QMouseEvent *event){setFromX(event->position().x());event->accept();}
void CompareSlider::mouseMoveEvent(QMouseEvent *event){if(event->buttons()&Qt::LeftButton)setFromX(event->position().x());event->accept();}

void CompareSlider::paintEvent(QPaintEvent *)
{
    QPainter p(this);p.setRenderHint(QPainter::Antialiasing);QRect frame=rect().adjusted(1,1,-1,-1);p.setPen(QPen(palette().color(QPalette::Mid),1));p.setBrush(palette().color(QPalette::AlternateBase));p.drawRoundedRect(frame,14,14);if(m_loading){QLinearGradient g(-80+m_phase,0,160+m_phase,0);QColor a=palette().color(QPalette::Mid),b=palette().color(QPalette::Base);g.setColorAt(0,a);g.setColorAt(.5,b);g.setColorAt(1,a);p.setPen(Qt::NoPen);p.setBrush(g);p.drawRoundedRect(frame.adjusted(1,1,-1,-1),13,13);p.setPen(palette().color(QPalette::PlaceholderText));p.drawText(frame,Qt::AlignCenter,tr("Generating preview…"));return;}if(!m_error.isEmpty()){p.setPen(QColor("#FF453A"));p.drawText(frame.adjusted(24,24,-24,-24),Qt::AlignCenter|Qt::TextWordWrap,m_error);return;}if(m_before.isNull()||m_after.isNull()){p.setPen(palette().color(QPalette::PlaceholderText));p.drawText(frame,Qt::AlignCenter,tr("Add a file, then generate a preview"));return;}auto target=[&](const QImage &image){QSize size=image.size();size.scale(frame.size()*m_zoom,Qt::KeepAspectRatio);QRect r(QPoint(),size);r.moveCenter(frame.center());return r;};const QRect beforeRect=target(m_before),afterRect=target(m_after);p.setClipRect(frame);p.drawImage(beforeRect,m_before);const int split=frame.left()+qRound(frame.width()*value()/100.0);p.save();p.setClipRect(QRect(split,frame.top(),frame.right()-split+1,frame.height()));p.drawImage(afterRect,m_after);p.restore();p.setClipping(false);p.setPen(QPen(Qt::white,2));p.drawLine(split,frame.top()+8,split,frame.bottom()-8);p.setPen(QPen(palette().color(QPalette::Highlight),2));p.setBrush(Qt::white);p.drawEllipse(QPointF(split,frame.center().y()),14,14);p.drawLine(split-4,frame.center().y(),split+4,frame.center().y());auto label=[&](const QString &text,bool right){QFont f=font();f.setPointSizeF(10);f.setWeight(QFont::DemiBold);p.setFont(f);const int width=QFontMetrics(f).horizontalAdvance(text)+18;QRect r(right?frame.right()-width-10:frame.left()+10,frame.top()+10,width,25);p.setPen(Qt::NoPen);p.setBrush(QColor(0,0,0,155));p.drawRoundedRect(r,8,8);p.setPen(Qt::white);p.drawText(r,Qt::AlignCenter,text);};label(tr("Original (bicubic)"),false);label(m_afterLabel.isEmpty()?tr("Upscaled"):m_afterLabel,true);
}
