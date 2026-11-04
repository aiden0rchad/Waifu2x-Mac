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

    My Github homepage: https://github.com/AaronFeng753
*/

#include "mainwindow.h"
#include "wizard_preview.h"

#include <QApplication>
#include <QAbstractItemView>
#include <QDirIterator>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QCheckBox>
#include <QDialog>
#include <QLineEdit>
#include <QMouseEvent>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QKeyEvent>
#include <QPainter>
#include <QSlider>
#include <QStandardPaths>
#include <QScrollArea>
#include <QSettings>
#include <QSocketNotifier>
#include <QTemporaryDir>
#include <QTimer>
#include <cstdlib>
#include <csignal>
#ifdef Q_OS_UNIX
#include <fcntl.h>
#include <unistd.h>
#endif

std::atomic_bool g_appQuitting{false};

class W2xApplication final : public QApplication
{
public:
    using QApplication::QApplication;
    void setMainWindow(MainWindow *window){mainWindow=window;}

protected:
    bool event(QEvent *event) override
    {
        if(event->type()==QEvent::Quit && mainWindow && !g_appQuitting.load(std::memory_order_relaxed))
        {
            mainWindow->close();
            return true;
        }
        return QApplication::event(event);
    }

private:
    MainWindow *mainWindow=nullptr;
};

#ifdef Q_OS_UNIX
static int terminationPipe[2]={-1,-1};

static void terminationSignalHandler(int)
{
    const char byte=1;
    if(terminationPipe[1]>=0)static_cast<void>(::write(terminationPipe[1],&byte,1));
}

static void installTerminationHandler(QCoreApplication &application)
{
    if(::pipe(terminationPipe)!=0)return;
    ::fcntl(terminationPipe[0],F_SETFL,O_NONBLOCK);
    ::fcntl(terminationPipe[1],F_SETFL,O_NONBLOCK);
    struct sigaction action{};
    action.sa_handler=terminationSignalHandler;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM,&action,nullptr);
    sigaction(SIGINT,&action,nullptr);
    auto *notifier=new QSocketNotifier(terminationPipe[0],QSocketNotifier::Read,&application);
    QObject::connect(notifier,&QSocketNotifier::activated,&application,[&application]{
        char bytes[32];
        while(::read(terminationPipe[0],bytes,sizeof(bytes))>0){}
        g_appQuitting.store(true,std::memory_order_relaxed);
        application.quit();
    });
}
#else
static void installTerminationHandler(QCoreApplication &){}
#endif

static int runQuitSelfTest()
{
    bool allPassed=true;
    for(const bool stuck:{false,true})
    {
        QTemporaryDir data(QDir::currentPath()+"/w2x-quit-XXXXXX");
        QProcess child;
        QProcessEnvironment environment=QProcessEnvironment::systemEnvironment();
        environment.insert("QT_QPA_PLATFORM",QGuiApplication::platformName());
        environment.insert("W2X_SELFTEST","quit");
        environment.insert("W2X_QUIT_CHILD","1");
        environment.insert("W2X_DATA_DIR",data.path());
        if(stuck)environment.insert("W2X_QUIT_STUCK","1");
        else environment.remove("W2X_QUIT_STUCK");
        child.setProcessEnvironment(environment);
        child.setProcessChannelMode(QProcess::ForwardedChannels);
        QElapsedTimer elapsed;
        elapsed.start();
        child.start(QCoreApplication::applicationFilePath(),{});
        const bool started=child.waitForStarted(1000);
        const bool finished=started&&child.waitForFinished(4000);
        const bool passed=finished&&child.exitStatus()==QProcess::NormalExit&&child.exitCode()==0;
        if(!finished){child.kill();child.waitForFinished(1000);}
        fprintf(stdout,"W2X_SELFTEST %s elapsed_ms=%lld %s\n",stuck?"quit-failsafe":"quit",elapsed.elapsed(),passed?"PASS":"FAIL");
        fflush(stdout);
        allPassed&=passed;
    }
    return allPassed?0:2;
}

static bool migrateLegacyData(const QString &newPath, const QStringList &oldPaths,
                              QSettings &legacy, QSettings &current)
{
    if(QFile::exists(newPath + "/settings.ini"))return true;
    if(!QDir().mkpath(newPath))return false;
    const QString newLists = newPath + "/FilesList_W2xEX";
    for(const QString &oldPath : oldPaths)
    {
        const QString oldLists = oldPath + "/FilesList_W2xEX";
        if(!QDir(oldLists).exists())continue;
        if(!QDir().mkpath(newLists))return false;
        QDirIterator files(oldLists, QDir::Files);
        while(files.hasNext())
        {
            const QString source = files.next();
            const QString target = newLists + "/" + QFileInfo(source).fileName();
            if(!QFile::exists(target) && !QFile::copy(source, target))return false;
        }
    }
    for(const QString &key : legacy.allKeys())
        if(key == "history/items" || key == "geometry" || key == "appearance" ||
           key.startsWith("presets/") || key.startsWith("wizard/") ||
           key.startsWith("estimate/") || key.startsWith("bench/"))
            if(!current.contains(key))current.setValue(key, legacy.value(key));
    current.sync();
    if(legacy.status()!=QSettings::NoError || current.status()!=QSettings::NoError)return false;
    for(const QString &oldPath : oldPaths)
    {
        if(!QFile::exists(oldPath + "/settings.ini"))continue;
        QSettings source(oldPath + "/settings.ini", QSettings::IniFormat);
        const QStringList excluded = {"settings/GIFScaleRatio", "settings/VideoScaleRatio",
            "settings/ImageDenoiseLevel", "settings/GIFDenoiseLevel", "settings/VideoDenoiseLevel"};
        const QStringList keys=source.allKeys();
        if(source.status()!=QSettings::NoError)return false;
        QSettings migrated(newPath + "/settings.ini", QSettings::IniFormat);
        for(const QString &key : keys)
            if(!excluded.contains(key))migrated.setValue(key,source.value(key));
        migrated.sync();
        return migrated.status()==QSettings::NoError;
    }
    return true;
}

static int runMigrationSelfTest()
{
    QTemporaryDir data(QDir::currentPath()+"/w2x-migration-XXXXXX");
    bool ok=data.isValid();
    const QStringList excluded={"GIFScaleRatio","VideoScaleRatio","ImageDenoiseLevel","GIFDenoiseLevel","VideoDenoiseLevel"};
    for(int preferred=0; preferred<3; ++preferred)
    {
        const QString root=data.path()+"/"+QString::number(preferred), destination=root+"/new";
        const QStringList sources={root+"/old",root+"/old/nested",root+"/older"};
        for(int i=preferred;i<sources.size();++i)
        {
            QDir().mkpath(sources[i]+"/FilesList_W2xEX");
            QSettings source(sources[i]+"/settings.ini",QSettings::IniFormat);
            source.setValue("settings/source",i);
            source.setValue("settings/ImageScaleRatio",4);
            for(const QString &key:excluded)source.setValue("settings/"+key,8);
            source.sync();
            QFile list(sources[i]+"/FilesList_W2xEX/saved.ini");
            ok &= list.open(QIODevice::WriteOnly) && list.write(QByteArray::number(i))>0;
        }
        QSettings legacy(root+"/legacy.ini",QSettings::IniFormat),current(root+"/current.ini",QSettings::IniFormat);
        const QStringList keys={"history/items","presets/custom","wizard/keepAwake","estimate/video","bench/7","geometry","appearance"};
        for(const QString &key:keys)legacy.setValue(key,QByteArray("saved"));
        legacy.setValue("unrelated",true);
        current.setValue("wizard/keepAwake",false);
        ok &= migrateLegacyData(destination,sources,legacy,current);
        QSettings migrated(destination+"/settings.ini",QSettings::IniFormat);
        ok &= migrated.value("settings/source").toInt()==preferred && migrated.value("settings/ImageScaleRatio").toInt()==4;
        for(const QString &key:excluded)ok &= !migrated.contains("settings/"+key);
        for(const QString &key:keys)ok &= current.contains(key);
        ok &= !current.value("wizard/keepAwake").toBool() && !current.contains("unrelated");
        QFile list(destination+"/FilesList_W2xEX/saved.ini");
        ok &= list.open(QIODevice::ReadOnly) && list.readAll()==QByteArray::number(preferred);
        legacy.setValue("geometry","changed");
        current.remove("geometry");
        ok &= migrateLegacyData(destination,sources,legacy,current) && !current.contains("geometry");
        for(int i=preferred;i<sources.size();++i)ok &= QFile::exists(sources[i]+"/settings.ini");
    }
    fprintf(stdout,"W2X_SELFTEST migration precedence/filtering/settings/idempotence %s\n",ok?"PASS":"FAIL");
    return ok?0:2;
}

int main(int argc, char *argv[])
{
    QCoreApplication::setAttribute(Qt::AA_EnableHighDpiScaling);//高分辨率屏幕支持
    W2xApplication a(argc,argv);
    QApplication::setWindowIcon(QIcon(":/wizard/icons/wizard/appicon.png"));
    QObject::connect(&a,&QCoreApplication::aboutToQuit,&a,[]{g_appQuitting.store(true,std::memory_order_relaxed);},Qt::DirectConnection);
    installTerminationHandler(a);
    QCoreApplication::setOrganizationName("Waifu2xMacGUI");
    QCoreApplication::setApplicationName("Waifu2xMacGUI");
    QGuiApplication::setApplicationDisplayName("Waifu2x-Mac");
    const QString automatedData=qEnvironmentVariable("W2X_DATA_DIR");if(!automatedData.isEmpty()){QSettings::setDefaultFormat(QSettings::IniFormat);QSettings::setPath(QSettings::IniFormat,QSettings::UserScope,automatedData);}
    if(qEnvironmentVariable("W2X_SELFTEST")=="migration")return runMigrationSelfTest();
#ifdef Q_OS_MACOS
    if(automatedData.isEmpty() && !qEnvironmentVariableIsSet("W2X_SELFTEST") &&
       !qEnvironmentVariableIsSet("W2X_SNAPSHOT_DIR") && !qEnvironmentVariableIsSet("W2X_PERF"))
    {
        const QString support=QDir::homePath()+"/Library/Application Support/";
        const QStringList oldPaths={support+"MacUpscaler",support+"MacUpscaler/MacUpscaler",
            support+"Waifu2x-Extension-GUI"};
        QSettings legacy("MacUpscaler","MacUpscaler"),current;
        if(!migrateLegacyData(W2xDataPath(),oldPaths,legacy,current))
        {
            qWarning("Waifu2x-Mac could not finish migrating legacy data; original data is unchanged.");
            return 1;
        }
    }
#endif
    if(qEnvironmentVariable("W2X_SELFTEST")=="quit"&&!qEnvironmentVariableIsSet("W2X_QUIT_CHILD"))return runQuitSelfTest();
    a.setQuitOnLastWindowClosed(false);//隐藏无窗口时保持运行
    MainWindow *w = new MainWindow;
    a.setMainWindow(w);
    QObject::connect(&a,&QCoreApplication::aboutToQuit,w,&MainWindow::PrepareForShutdown,Qt::DirectConnection);
    w->show();
    if(qEnvironmentVariable("W2X_SELFTEST")=="quit")
    {
        w->move(-10000,-10000);
        if(qEnvironmentVariableIsSet("W2X_QUIT_STUCK"))static_cast<void>(QtConcurrent::run([]{QThread::sleep(10); }));
        QTimer::singleShot(500,&a,&QCoreApplication::quit);
    }
    auto execWithFailSafe=[&a]{
        const int result=a.exec();
        if(!QThreadPool::globalInstance()->waitForDone(2000))
        {
            QSettings settings;
            settings.sync();
            fflush(nullptr);
            // Last resort: never let QApplication's global-pool destructor hang the process.
            std::_Exit(0);
        }
        return result;
    };
    if(qEnvironmentVariable("W2X_SELFTEST")=="quit")return execWithFailSafe();
    if(qEnvironmentVariable("W2X_SELFTEST")=="preview")
    {
        QTimer::singleShot(0,w,[w]{
            bool ok=true;w->wizardTargetEnabled=true;w->wizardTargetWidth->setValue(3840);w->wizardTargetHeight->setValue(2160);const double effective=w->Wizard_PreviewEffectiveFactor(QSize(640,360));const bool effectiveOk=qFuzzyCompare(effective,6.0);fprintf(stdout,"W2X_SELFTEST preview-effective 640x360->3840x2160 factor=%.1f %s\n",effective,effectiveOk?"PASS":"FAIL");ok&=effectiveOk;w->wizardTargetEnabled=false;const QList<int> factors={2,3,4,6,8};auto *cugan=w->findChild<QComboBox *>("comboBox_Model_RealCUGAN"),*esrgan=w->findChild<QComboBox *>("comboBox_Model_RealESRGAN"),*realsr=w->findChild<QComboBox *>("comboBox_Model_RealsrNCNNVulkan");auto check=[w,&ok](int engine,int model,int requested,const QString &name){const QList<int> plan=w->Wizard_PreviewPassPlan(engine,requested);int product=1;bool supported=!plan.isEmpty();for(int pass:plan){product*=pass;if(engine==8)supported&=pass>=2&&pass<=(model==0?3:4);else if(engine==9)supported&=pass==RealESRGANModels[model].passFactor;else if(engine==5)supported&=pass==4;}supported&=product>=requested;if(engine==7)supported&=plan.size()==1;QStringList parts;for(int pass:plan)parts<<QString::number(pass);const QByteArray label=name.toUtf8(),passes=parts.join("x").toUtf8();fprintf(stdout,"W2X_SELFTEST preview-plan %s requested=%d passes=%s product=%d %s\n",label.constData(),requested,passes.constData(),product,supported?"PASS":"FAIL");ok&=supported;};
            for(int factor:factors)check(7,0,factor,"MetalFX/Spatial");for(int model=0;model<cugan->count();++model){cugan->setCurrentIndex(model);for(int factor:factors)check(8,model,factor,"Real-CUGAN/"+QStringList{"Pro","SE","No-denoise"}.value(model));}for(int model=0;model<RealESRGANModelCount;++model){if(esrgan->findData(model)<0)esrgan->addItem(QString::fromLatin1(RealESRGANModels[model].name),model);w->SetComboId(esrgan,model);for(int factor:factors)check(9,model,factor,"Real-ESRGAN/"+QString::fromLatin1(RealESRGANModels[model].name));}for(int model=0;model<realsr->count();++model){realsr->setCurrentIndex(model);for(int factor:factors)check(5,model,factor,"RealSR/"+QString::number(model));}
            const QString testRoot=qEnvironmentVariable("W2X_DATA_DIR",QDir::tempPath());QDir().mkpath(testRoot);QTemporaryDir sample(testRoot+"/preview-XXXXXX");sample.setAutoRemove(false);QImage image(256,256,QImage::Format_RGB32);for(int y=0;y<image.height();++y)for(int x=0;x<image.width();++x)image.setPixelColor(x,y,QColor::fromHsv((x+y)%360,180,80+(x%176)));const QString path=sample.path()+"/preview.png";image.save(path);w->Table_image_insert_fileName_fullPath("preview.png",path);w->Table_FileCount_reload();w->wizardTargetEnabled=false;w->findChild<QDoubleSpinBox *>("doubleSpinBox_ScaleRatio_image")->setValue(2);cugan->setCurrentIndex(0);w->SetComboId(esrgan,0);realsr->setCurrentIndex(0);w->Wizard_ShowStep(1);
            for(const auto &test:QList<QPair<int,QString>>{{7,"MetalFX"},{8,"Real-CUGAN"},{9,"Real-ESRGAN"},{5,"RealSR"}}){for(const char *combo:{"comboBox_Engine_Image","comboBox_Engine_GIF","comboBox_Engine_Video"})w->SetComboId(w->findChild<QComboBox *>(combo),test.first);w->wizardPreviewSettingsKey.clear();QElapsedTimer elapsed;elapsed.start();w->Wizard_RequestPreview(true);QEventLoop loop;QTimer poll,timeout;poll.setInterval(25);timeout.setSingleShot(true);QObject::connect(&poll,&QTimer::timeout,&loop,[w,&loop]{if(w->wizardCompare->property("previewComplete").toBool())loop.quit();});QObject::connect(&timeout,&QTimer::timeout,&loop,&QEventLoop::quit);poll.start();timeout.start(60000);loop.exec();const QImage output=w->wizardPreviewAfterCache.value(w->wizardPreviewSettingsKey);const QString error=w->wizardCompare->property("previewError").toString();const bool noGpu=error.contains("VK_ERROR_INCOMPATIBLE_DRIVER",Qt::CaseInsensitive)||error.contains("unsupported GPU",Qt::CaseInsensitive)||error.contains("not supported on this GPU",Qt::CaseInsensitive)||error.contains("not supported on this device",Qt::CaseInsensitive)||error.contains("no Metal device",Qt::CaseInsensitive)||error.contains("vkCreateInstance failed",Qt::CaseInsensitive)||error.contains("no Vulkan device",Qt::CaseInsensitive);if(noGpu)fprintf(stdout,"W2X_PREVIEW %s SKIP no Metal device (%s)\n",test.second.toUtf8().constData(),error.left(160).toUtf8().constData());else{fprintf(stdout,"W2X_PREVIEW %s size=%dx%d elapsed_ms=%lld%s%s\n",test.second.toUtf8().constData(),output.width(),output.height(),elapsed.elapsed(),error.isEmpty()?"":" error=",error.toUtf8().constData());ok&=!output.isNull();}w->Wizard_CancelPreview();}fflush(stdout);std::_Exit(ok?0:2);
        });
        return execWithFailSafe();
    }
    if(qEnvironmentVariable("W2X_SELFTEST")=="resume")
    {
        QTimer::singleShot(0,w,[w]{
            const QString testRoot=qEnvironmentVariable("W2X_DATA_DIR",QDir::currentPath());QDir().mkpath(testRoot);QTemporaryDir job(testRoot+"/resume-XXXXXX");const QString split=job.path()+"/incident_SplitFrames_W2xEX",scaled=split+"/ScaledFrames_W2xEX";QDir().mkpath(scaled);QImage frame(2,2,QImage::Format_RGB32);frame.fill(Qt::red);for(int i=0;i<10;++i){const QString name=QString("%1.png").arg(i,4,10,QChar('0'));frame.save(split+"/"+name);if(i<3)frame.save(scaled+"/"+name);}QFile zero(scaled+"/zero.png");static_cast<void>(zero.open(QIODevice::WriteOnly));zero.close();const int repaired=w->NormalizeInterruptedFrameCache(split,scaled);const int splitCount=w->file_getFileNames_in_Folder_nofilter(split).size(),scaledCount=w->file_getFileNames_in_Folder_nofilter(scaled).size();const bool ok=job.isValid()&&repaired==4&&splitCount+scaledCount==10&&!QFile::exists(scaled+"/zero.png");fprintf(stdout,"W2X_SELFTEST resume repaired=%d split=%d scaled=%d zero_removed=%d %s\n",repaired,splitCount,scaledCount,!QFile::exists(scaled+"/zero.png"),ok?"PASS":"FAIL");fflush(stdout);std::_Exit(ok?0:2);
        });
        return execWithFailSafe();
    }
    if(qEnvironmentVariableIsSet("W2X_SELFTEST"))
    {
        QTimer::singleShot(0,w,[w]{
            QTemporaryDir sample;sample.setAutoRemove(false);QImage image(640,360,QImage::Format_RGB32);image.fill(QColor("#0A84FF"));const QString path=sample.path()+"/selftest.gif";image.save(path,"PNG");w->Table_gif_insert_fileName_fullPath("selftest.gif",path);w->Table_FileCount_reload();w->Wizard_ApplyPreset(QObject::tr("Anime wallpaper 4K"));
            QTimer::singleShot(0,w,[w]{if(QWidget *modal=qApp->activeModalWidget()){if(auto *encoder=modal->findChild<QComboBox *>("advEncoder"))encoder->setCurrentIndex(1);if(auto *crf=modal->findChild<QSlider *>("advCrf"))crf->setValue(20);if(w->wizardAdvancedTta)w->wizardAdvancedTta->setChecked(true);qobject_cast<QDialog *>(modal)->accept();}});w->Wizard_ShowAdvanced(2);w->Wizard_SyncFromLegacy();
            const bool basics=w->wizardTargetWidth->value()==3840&&w->wizardTargetHeight->value()==2160&&w->findChild<QLineEdit *>("lineEdit_encoder_vid")->text().contains("265")&&w->findChild<QLineEdit *>("lineEdit_ExCommand_output")->text().contains("-crf 20")&&w->findChild<QCheckBox *>("checkBox_TTA_RealCUGAN")->isChecked();w->Wizard_ShowStep(0);w->Wizard_RefreshNow();QLabel *filesHeader=nullptr;for(QLabel *chip:w->wizardRoot->findChildren<QLabel*>("headerChip"))if(chip->property("stepHeaderChip").toInt()==0){filesHeader=chip;break;}const bool plurals=filesHeader&&filesHeader->text().contains("1 file")&&w->wizardFilesFooter->text().contains("1 file")&&w->wizardFilesFooter->text().contains("1 GIF");fprintf(stdout,"W2X_SELFTEST plurals header=%s footer=%s %s\n",filesHeader?filesHeader->text().toUtf8().constData():"<missing>",w->wizardFilesFooter->text().toUtf8().constData(),plurals?"PASS":"FAIL");w->Wizard_ShowStep(2);w->Wizard_RefreshNow();const bool estimates=!w->wizardEstimateResolution->text().isEmpty()&&!w->wizardEstimateSize->text().isEmpty()&&!w->wizardEstimateTime->text().isEmpty()&&(w->wizardEstimateSize->text().startsWith("about ")||w->wizardEstimateSize->text()==QString::fromUtf8("—"))&&(w->wizardEstimateTime->text().startsWith("about ")||w->wizardEstimateTime->text()==QObject::tr("After your first run"));fprintf(stdout,"W2X_SELFTEST estimates resolution=%s size=%s time=%s %s\n",w->wizardEstimateResolution->text().toUtf8().constData(),w->wizardEstimateSize->text().toUtf8().constData(),w->wizardEstimateTime->text().toUtf8().constData(),estimates?"PASS":"FAIL");const qint64 imageEstimate=MainWindow::Wizard_EstimateBytes(0,1024*1024,640*360,1280*720,-1,0,18,false),videoEstimate=MainWindow::Wizard_EstimateBytes(2,1060000,640*360,1280*720,25,400000,18,false),hevcEstimate=MainWindow::Wizard_EstimateBytes(2,1060000,640*360,1280*720,25,400000,18,true),learnedEstimate=MainWindow::Wizard_EstimateBytes(2,1060000,640*360,1280*720,-1,0,18,false,1.5);const bool estimateMath=imageEstimate>3*1024*1024&&imageEstimate<4*1024*1024&&videoEstimate>8*1024*1024&&videoEstimate<10*1024*1024&&hevcEstimate<videoEstimate&&learnedEstimate>1400000&&learnedEstimate<1500000&&MainWindow::Wizard_EstimateBytes(2,1060000,640*360,1280*720,-1,400000,18,false)==0;fprintf(stdout,"W2X_SELFTEST estimate-math image=%lld video=%lld hevc=%lld learned=%lld %s\n",imageEstimate,videoEstimate,hevcEstimate,learnedEstimate,estimateMath?"PASS":"FAIL");const bool captions=MainWindow::Wizard_FormatMediaCaption(2,QSize(640,360),24.9,740)==QString::fromUtf8("640 × 360 · 0:24 · 740 frames")&&MainWindow::Wizard_FormatMediaCaption(1,QSize(108,160),-1,50)==QString::fromUtf8("108 × 160 · 50 frames")&&MainWindow::Wizard_FormatMediaCaption(0,QSize(1920,1080))==QString::fromUtf8("1920 × 1080");fprintf(stdout,"W2X_SELFTEST captions %s\n",captions?"PASS":"FAIL");w->wizardPreviewSettingsKey.clear();w->Wizard_ShowStep(1);QApplication::processEvents();const bool autoPreview=w->wizardGeneratePreview->isEnabled()&&w->wizardPreviewTimer->isActive();fprintf(stdout,"W2X_SELFTEST auto-preview enabled=%d scheduled=%d %s\n",w->wizardGeneratePreview->isEnabled(),w->wizardPreviewTimer->isActive(),autoPreview?"PASS":"FAIL");w->Wizard_CancelPreview();w->wizardCompare->setProperty("snapshotReady",true);bool ok=autoPreview&&plurals&&estimates&&estimateMath&&captions;
            w->Wizard_SelectEngine(7);QTimer::singleShot(0,w,[]{if(auto *modal=qobject_cast<QDialog *>(qApp->activeModalWidget()))modal->accept();});w->Wizard_ShowAdvanced(0);const bool balanced=w->wizardAdvancedDialog->findChild<QComboBox *>("advancedThreads")->currentText()==QObject::tr("Balanced");const bool metal=w->wizardAdvancedMetalInfo&&!w->wizardAdvancedMetalInfo->isHidden()&&w->wizardAdvancedTileRow->isHidden()&&w->wizardAdvancedGpuRow->isHidden()&&w->wizardAdvancedTtaRow->isHidden()&&w->wizardAdvancedThreadsRow->isHidden()&&balanced;fprintf(stdout,"W2X_SELFTEST advanced-metalfx info=%d tuning-hidden=%d balanced=%d %s\n",w->wizardAdvancedMetalInfo&&!w->wizardAdvancedMetalInfo->isHidden(),w->wizardAdvancedTileRow->isHidden()&&w->wizardAdvancedGpuRow->isHidden()&&w->wizardAdvancedTtaRow->isHidden()&&w->wizardAdvancedThreadsRow->isHidden(),balanced,metal?"PASS":"FAIL");bool rail=w->wizardAdvancedTabs&&w->wizardAdvancedTabs->buttons().size()==5;for(QAbstractButton *button:w->wizardAdvancedTabs->buttons())rail=rail&&button->isCheckable()&&!button->text().isEmpty()&&!button->accessibleName().isEmpty();w->wizardAdvancedTabs->button(4)->click();rail=rail&&w->wizardAdvancedPages->currentIndex()==4;fprintf(stdout,"W2X_SELFTEST advanced-rail buttons=%d page=%d %s\n",int(w->wizardAdvancedTabs->buttons().size()),w->wizardAdvancedPages->currentIndex(),rail?"PASS":"FAIL");ok&=metal&&rail;
            auto mouseClick=[](QAbstractButton *button){const QPointF local=button->rect().center();const QPointF global=button->mapToGlobal(local.toPoint());QMouseEvent press(QEvent::MouseButtonPress,local,global,Qt::LeftButton,Qt::LeftButton,Qt::NoModifier);QApplication::sendEvent(button,&press);QMouseEvent release(QEvent::MouseButtonRelease,local,global,Qt::LeftButton,Qt::NoButton,Qt::NoModifier);QApplication::sendEvent(button,&release);QApplication::processEvents();};
            auto checkSelection=[w,&ok](const QString &kind,const QString &name,int expected,bool photo){QApplication::processEvents();w->Wizard_RefreshNow();QComboBox *image=w->findChild<QComboBox *>("comboBox_Engine_Image"),*gif=w->findChild<QComboBox *>("comboBox_Engine_GIF"),*video=w->findChild<QComboBox *>("comboBox_Engine_Video");QPushButton *checked=nullptr;int checkedCount=0;for(QPushButton *button:w->wizardRoot->findChildren<QPushButton*>())if(button->property("engineId").isValid()&&button->isChecked()){checked=button;++checkedCount;}QLabel *header=nullptr;for(QLabel *chip:w->wizardRoot->findChildren<QLabel*>("headerChip"))if(chip->property("stepHeaderChip").toInt()==1){header=chip;break;}const bool ids=w->ComboId(image)==expected&&w->ComboId(gif)==expected&&w->ComboId(video)==expected;const bool card=checkedCount==1&&checked&&checked->property("photoCard").toBool()==photo&&(!photo||expected==5||checked->property("engineId").toInt()==9)&&((photo)||checked->property("engineId").toInt()==expected);const QString engineName=expected==7?QStringLiteral("MetalFX"):expected==8?QStringLiteral("Real-CUGAN"):expected==9?QStringLiteral("Real-ESRGAN"):QStringLiteral("RealSR");const bool headerOk=header&&header->text().contains(engineName),sessionOk=w->wizardSessionEngine&&w->wizardSessionEngine->text().contains(engineName);const bool pass=ids&&card&&headerOk&&sessionOk;ok&=pass;fprintf(stdout,"W2X_SELFTEST %s %s ids=%d/%d/%d card=%d header=%d session=%d %s\n",kind.toUtf8().constData(),name.toUtf8().constData(),w->ComboId(image),w->ComboId(gif),w->ComboId(video),card,headerOk,sessionOk,pass?"PASS":"FAIL");};
            QList<QPushButton*> cards;for(QPushButton *button:w->wizardRoot->findChildren<QPushButton*>())if(button->property("engineId").isValid())cards<<button;std::sort(cards.begin(),cards.end(),[](QPushButton *a,QPushButton *b){return a->property("engineOrder").toInt()<b->property("engineOrder").toInt();});const QList<int> cardIds={7,8,9,9};for(int i=0;i<cards.size()&&i<cardIds.size();++i){cards[i]->click();checkSelection(QStringLiteral("engine-click"),cards[i]->property("engineTitle").toString(),w->ComboId(w->findChild<QComboBox *>("comboBox_Engine_Image"))==5?5:cardIds[i],i==3);cards[(i+1)%cards.size()]->click();mouseClick(cards[i]);checkSelection(QStringLiteral("engine-mouse"),cards[i]->property("engineTitle").toString(),w->ComboId(w->findChild<QComboBox *>("comboBox_Engine_Image"))==5?5:cardIds[i],i==3);}
            const QList<QPair<QString,int>> presets={{QObject::tr("Anime wallpaper 4K"),8},{QObject::tr("Photo restore"),9},{QObject::tr("Quick preview"),7},{QObject::tr("Smooth GIF"),8}};for(const auto &preset:presets){QPushButton *button=nullptr;for(QPushButton *candidate:w->wizardPresetRow->findChildren<QPushButton*>())if(candidate->property("presetName").toString()==preset.first){button=candidate;break;}if(button){button->click();checkSelection(QStringLiteral("preset-click"),preset.first,preset.second,preset.first==QObject::tr("Photo restore"));mouseClick(button);checkSelection(QStringLiteral("preset-mouse"),preset.first,preset.second,preset.first==QObject::tr("Photo restore"));}else{ok=false;fprintf(stdout,"W2X_SELFTEST preset %s missing FAIL\n",preset.first.toUtf8().constData());}}
            if(w->wizardTargetModeGroup->button(0))w->wizardTargetModeGroup->button(0)->click();for(int factor:{2,3,4,8}){auto checkScale=[w,&ok,factor](const char *path){const bool pass=w->wizardSizeGroup->checkedId()==factor&&w->findChild<QDoubleSpinBox *>("doubleSpinBox_ScaleRatio_image")->value()==factor&&w->findChild<QDoubleSpinBox *>("doubleSpinBox_ScaleRatio_gif")->value()==factor&&w->findChild<QDoubleSpinBox *>("doubleSpinBox_ScaleRatio_video")->value()==factor;ok&=pass;fprintf(stdout,"W2X_SELFTEST size-%s %dx checked=%d %s\n",path,factor,w->wizardSizeGroup->checkedId(),pass?"PASS":"FAIL");};w->wizardSizeGroup->button(factor)->click();checkScale("click");mouseClick(w->wizardSizeGroup->button(factor));checkScale("mouse");}
            cards[1]->click();if(QComboBox *model=w->findChild<QComboBox *>("comboBox_Model_RealCUGAN"))model->setCurrentIndex(qMin(1,model->count()-1));w->Wizard_RefreshNow();for(int level=0;level<4;++level){auto checkNoise=[w,&ok,level](const char *path){const bool pass=w->wizardNoiseGroup->checkedId()==level&&w->findChild<QSpinBox *>("spinBox_DenoiseLevel_image")->value()==level&&w->findChild<QSpinBox *>("spinBox_DenoiseLevel_gif")->value()==level&&w->findChild<QSpinBox *>("spinBox_DenoiseLevel_video")->value()==level;ok&=pass;fprintf(stdout,"W2X_SELFTEST noise-%s level=%d checked=%d %s\n",path,level,w->wizardNoiseGroup->checkedId(),pass?"PASS":"FAIL");};w->wizardNoiseGroup->button(level)->click();checkNoise("click");mouseClick(w->wizardNoiseGroup->button(level));checkNoise("mouse");}
            cards[3]->click();for(int index=0;index<w->wizardPhotoModel->count();++index){w->wizardPhotoModel->setCurrentIndex(index);const int expected=w->wizardPhotoModel->currentData().toInt()/100;checkSelection(QStringLiteral("photos-model"),w->wizardPhotoModel->currentText(),expected,true);}
            cards[0]->click();cards[0]->setFocus(Qt::OtherFocusReason);QKeyEvent arrow(QEvent::KeyPress,Qt::Key_Right,Qt::NoModifier);QApplication::sendEvent(cards[0],&arrow);QApplication::processEvents();const bool keyboard=(cards[1]->focusPolicy()&Qt::TabFocus)&&cards[1]->property("keyboardFocus").toBool();checkSelection(QStringLiteral("engine-arrow"),QStringLiteral("Right"),8,false);ok&=keyboard;fprintf(stdout,"W2X_SELFTEST engine-arrow tab-focus=%d ring=%d %s\n",bool(cards[1]->focusPolicy()&Qt::TabFocus),cards[1]->property("keyboardFocus").toBool(),keyboard?"PASS":"FAIL");
            ok&=basics;fprintf(stdout,"W2X_SELFTEST advanced %s\n",basics?"PASS":"FAIL");fflush(stdout);std::_Exit(ok?0:2);
        });
        return execWithFailSafe();
    }
    if(qEnvironmentVariableIsSet("W2X_PERF"))
    {
        QTimer::singleShot(0, w, [w] {
            const QString path = QStringLiteral("/Users/rolandleyco/waifu2xmac/wallpaper/wallpaper_cugan_810_smaller.gif");
            w->Table_gif_insert_fileName_fullPath(QFileInfo(path).fileName(), path);
            w->Table_FileCount_reload();
            QApplication::processEvents();
            w->Wizard_ShowStep(0);
            for(int step = 1; step < 4; ++step)
            {
                QElapsedTimer timer;
                timer.start();
                w->Wizard_ShowStep(step);
                fprintf(stdout, "W2X_PERF Step %d->%d: %lld ms\n", step, step + 1, timer.elapsed());
            }
            fflush(stdout);
            std::_Exit(0);
        });
        return execWithFailSafe();
    }
    const QString snapshotDir = qEnvironmentVariable("W2X_SNAPSHOT_DIR");
    if (!snapshotDir.isEmpty()) {
      QTimer::singleShot(500, w, [w, snapshotDir] {
        QDir().mkpath(snapshotDir);
        const QString scheme = qEnvironmentVariable("W2X_SCHEME", "light");
        auto save = [w, snapshotDir, scheme](const QString &name) {
          QApplication::processEvents();
          return w->grab().save(snapshotDir + "/" + name + "-" + scheme +
                                ".png");
        };
        QDir().mkpath(snapshotDir + "/data/recent");
        QJsonArray recent;
        for (int i = 0; i < 3; ++i) {
          QImage image(180, 120, QImage::Format_RGB32);
          image.fill(QList<QColor>{QColor("#0A84FF"), QColor("#5E5CE6"),
                                   QColor("#FF9F0A")}[i]);
          const QString path =
              snapshotDir + QString("/data/recent/recent-%1.png").arg(i + 1);
          image.save(path);
          recent.append(QJsonObject{
              {"output", path},
              {"name", QString("Recent-%1.png").arg(i + 1)},
              {"resolution",
               QString("%1 × %2").arg(640 + i * 320).arg(400 + i * 200)},
              {"when", i ? QObject::tr("Yesterday") : QObject::tr("Just now")},
              {"thumb", path}});
        }
        QSettings().setValue("history/items", QJsonDocument(recent).toJson(
                                                  QJsonDocument::Compact));
        w->Wizard_RefreshNow();
        w->Wizard_ShowStep(0);
        save("step1-empty");
        QTemporaryDir samples(snapshotDir + "/samples-XXXXXX");
        const QList<QColor> colors = {"#0A84FF", "#5E5CE6", "#FF9F0A",
                                      "#32D74B", "#FF375F", "#64D2FF"};
        for (int i = 0; i < colors.size(); ++i) {
          QImage image(320, 220, QImage::Format_RGB32);
          image.fill(colors[i]);
          const QString path =
              samples.path() + QString("/Sample-%1.png").arg(i + 1);
          image.save(path);
          w->Table_image_insert_fileName_fullPath(QFileInfo(path).fileName(),
                                                  path);
        }
        w->Table_FileCount_reload();
        QEventLoop thumbnails;
        QTimer::singleShot(400, &thumbnails, &QEventLoop::quit);
        thumbnails.exec();
        w->Wizard_Refresh();
        save("step1");
        save("step1-files");
        for (int step = 1; step < 4; ++step) {
          w->Wizard_ShowStep(step);
          if (step == 1 && w->wizardTargetModeGroup) {
            w->wizardTargetModeGroup->button(1)->click();
            w->Wizard_CancelPreview();
            QImage before(384, 216, QImage::Format_RGB32),
                after(384, 216, QImage::Format_RGB32);
            before.fill(QColor("#64748B"));
            QPainter painter(&after);
            QLinearGradient gradient(0, 0, 384, 216);
            gradient.setColorAt(0, QColor("#0A84FF"));
            gradient.setColorAt(1, QColor("#5E5CE6"));
            painter.fillRect(after.rect(), gradient);
            painter.setPen(QPen(Qt::white, 6));
            for (int i = 24; i < 384; i += 48)
              painter.drawLine(i, 0, i, 216);
            painter.end();
            w->Wizard_SetPreviewImages(before, after, QObject::tr("Real-CUGAN Pro · 8×"));
            w->wizardPreviewStatus->setText(QObject::tr("Preview ran 3 passes (2× then 2× then 2×) like the real job"));
          }
          save(QString("step%1").arg(step + 1));
          if (step == 1) {
            save("step2-preview");
            const QSize originalSize = w->size();
            for (const auto &capture :
                 QList<QPair<QSize, QString>>{{QSize(980, 680), "980x680"},
                                              {QSize(1180, 800), "1180x800"},
                                              {QSize(1180, 852), "1180x852"},
                                              {QSize(1440, 900), "1440x900"}}) {
              w->resize(capture.first);
              save("step2-preview-" + capture.second);
            }
            w->resize(1180, 852);
            if (auto *scroll =
                    qobject_cast<QScrollArea *>(w->wizardStack->currentWidget())) {
              QApplication::processEvents();
              scroll->verticalScrollBar()->setValue(
                  scroll->verticalScrollBar()->maximum());
              QApplication::processEvents();
              save("step2-compare-1180x852");
              scroll->verticalScrollBar()->setValue(0);
            }
            w->resize(originalSize);
          }
        }
        w->Wizard_ShowStep(1);
        if (auto *photos = w->findChild<QPushButton *>("photosCard"))
          photos->click();
        save("step2-photos");
        const QStringList advancedNames = {
            "adv-engine", "adv-output", "adv-video", "adv-gif", "adv-system"};
        w->Wizard_SelectEngine(8);
        for (int page = 0; page < advancedNames.size(); ++page) {
          QTimer::singleShot(100, w,
                             [snapshotDir, scheme, name = advancedNames[page]] {
                               if (QWidget *modal = qApp->activeModalWidget()) {
                                 QPixmap capture=modal->grab();QComboBox *openCombo=nullptr;for(QComboBox *combo:modal->findChildren<QComboBox*>())if(combo->isVisible()){openCombo=combo;break;}if(openCombo){openCombo->showPopup();QApplication::processEvents();QWidget *popup=openCombo->view()->window();QPainter painter(&capture);painter.drawPixmap(modal->mapFromGlobal(popup->mapToGlobal(QPoint())),popup->grab());painter.end();openCombo->hidePopup();}
                                 capture.save(snapshotDir + "/" + name + "-" + scheme + ".png");
                                 qobject_cast<QDialog *>(modal)->accept();
                               }
                             });
          w->Wizard_ShowAdvanced(page);
        }
        w->Wizard_ShowStep(2);
        save("step3-advanced");
        w->Wizard_ShowStep(3);
        for (QStandardItemModel *model :
             {w->Table_model_image, w->Table_model_gif, w->Table_model_video})
          model->removeRows(0, model->rowCount());
        QImage gifFrame(108, 160, QImage::Format_RGB32);
        for (int y = 0; y < gifFrame.height(); ++y)
          for (int x = 0; x < gifFrame.width(); ++x)
            gifFrame.setPixelColor(
                x, y, QColor::fromHsv((x * 7 + y * 3) % 360, 190,
                                      110 + (x * y) % 140));
        const QString gifPath = samples.path() + "/test_a.gif",
                      gifOutput = samples.path() + "/test_a_upscaled.png";
        gifFrame.save(gifPath, "PNG");
        gifFrame
            .scaled(216, 320, Qt::IgnoreAspectRatio, Qt::SmoothTransformation)
            .save(gifOutput);
        QImage photoFrame(180, 120, QImage::Format_RGB32);
        for (int y = 0; y < photoFrame.height(); ++y)
          for (int x = 0; x < photoFrame.width(); ++x)
            photoFrame.setPixelColor(
                x, y, QColor::fromHsv((x * 3 + y * 5) % 360, 170,
                                      100 + (x * y) % 150));
        const QString photoPath = samples.path() + "/test_b.png",
                      photoOutput = samples.path() + "/test_b_upscaled.png";
        photoFrame.save(photoPath);
        photoFrame
            .scaled(360, 240, Qt::IgnoreAspectRatio, Qt::SmoothTransformation)
            .save(photoOutput);
        w->Table_gif_insert_fileName_fullPath(QFileInfo(gifPath).fileName(),
                                              gifPath);
        w->Table_image_insert_fileName_fullPath(QFileInfo(photoPath).fileName(),
                                                photoPath);
        w->Table_FileCount_reload();
        w->Wizard_Refresh();
        save("step4-idle");
        w->Wizard_SetRunning(true);
        w->Table_model_gif->setItem(
            0, 1, new QStandardItem(QObject::tr("Processing")));
        w->progressbar_setRange_min_max(0, 2);
        w->progressbar_SetToMax(0);
        w->CurrentFileProgress_Start("test_a.gif", 100);
        w->CurrentFileProgress_progressbar_SetFinishedValue(40);
        if (auto *elapsed = w->findChild<QLabel *>("label_TimeCost"))
          elapsed->setText("0:10");
        if (auto *remaining = w->findChild<QLabel *>("label_TimeRemain"))
          remaining->setText("0:15");
        w->pushButton_Stop_setEnabled_self(true);
        w->Wizard_Refresh();
        save("running-40");
        save("step4-running");
        save("step5");
        for (QStandardItemModel *model :
             {w->Table_model_image, w->Table_model_gif, w->Table_model_video})
          for (int row = 0; row < model->rowCount(); ++row)
            model->setItem(row, 1, new QStandardItem(QObject::tr("Finished")));
        w->Wizard_SetDone();
        save("done");
        save("done-gallery");
        save("step6");
        QTimer::singleShot(100, w, [snapshotDir, scheme] {
          if (QWidget *modal = qApp->activeModalWidget()) {
            modal->grab().save(snapshotDir + "/settings-" + scheme + ".png");
            modal->close();
          }
        });
        w->Wizard_ShowSettings();
        QDir(snapshotDir + "/data").removeRecursively();
        const QDir snapshots(snapshotDir);
        for (const QString &name : snapshots.entryList(
                 {"samples-*"}, QDir::Dirs | QDir::NoDotAndDotDot))
          QDir(snapshots.filePath(name)).removeRecursively();
        QTimer::singleShot(0, qApp, &QApplication::quit);
        std::_Exit(0);
      });
    }
    return execWithFailSafe();
}

/*
Change log:

****************** 补全中文翻译 ***********************

v3.41.02-beta:
- Fix bug: Unable to assemble APNG when there are "%" in the path.

v3.41.01-beta:
- New Feature: APNG(Animated PNG) support.
- Improve GUI.
- Some other improvements.

v3.31.21-beta:
- Performance optimization.
- Update FFmpeg, ImageMagick.
- Some other improvements.

--------------------------------------------------------------------------
To do:
- APNG插件兼容性测试
- 找一个性能更好的apng组装插件(试试ffmpeg)
- 添加对"图片文件夹"的支持,一次处理一个文件夹.
- 改进自动调整引擎设定
- 插帧时避免黑帧混乱,避免转场混乱 (插帧后的帧编号 = N*2-1)
- 自动将GIF转换为mp4
- 在SRMD和REALSR正式加入cpu支持后, 在GPU ID tooltip上添加[★ "-1" is CPU,others are GPUs ★]
- CRF参数调整支持
- 自动监控文件夹
---------------------------------------------------------------------------
Integrated component:
- gifsicle version 1.92
- SoX 14.4.2-win32
- waifu2x-caffe 1.2.0.4
- Waifu2x-converter 9e0284ae23d43c990efb6320253ff0f1e3776854
- Waifu2x-NCNN-Vulkan 20210210
- SRMD-NCNN-Vulkan 20210210
- RealSR-NCNN-Vulkan 20210210
- ImageMagick 7.0.11-8-portable-Q16-x64
- Anime4KCPP v2.5.0
- FFmpeg 2021-04-20-git-718e03e5f2-full_build
- NirCmd v2.86
- Ghostscript 9.53.3
- GNU Wget 1.20.3
- rife-ncnn-vulkan 20210227
- cain-ncnn-vulkan 20210210
---------------------------------------------------------------------------
Icons made by :
Freepik (https://www.flaticon.com/authors/freepik) From Flaticon : https://www.flaticon.com/
Roundicons (https://www.flaticon.com/authors/roundicons) From Flaticon : https://www.flaticon.com/
Icongeek26 (https://www.flaticon.com/authors/Icongeek26) From Flaticon : https://www.flaticon.com/
*/
