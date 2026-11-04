#pragma once

#include <QImage>
#include <QSlider>

class QTimer;

class CompareSlider final : public QSlider
{
    Q_OBJECT
public:
    explicit CompareSlider(QWidget *parent=nullptr);
    void setImages(const QImage &before,const QImage &after,const QString &afterLabel);
    void setLoading(bool loading);
    void setError(const QString &message);
    void setZoom(int zoom);
protected:
    void paintEvent(QPaintEvent *) override;
    void mousePressEvent(QMouseEvent *) override;
    void mouseMoveEvent(QMouseEvent *) override;
private:
    void setFromX(qreal x);
    QImage m_before,m_after;
    QString m_afterLabel,m_error;
    QTimer *m_shimmer=nullptr;
    int m_phase=0,m_zoom=1;
    bool m_loading=false;
};
