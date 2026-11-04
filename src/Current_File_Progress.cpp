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
#include "ui_mainwindow.h"

/*
开始处理当前文件
*/
void MainWindow::CurrentFileProgress_Start(QString FileName,int FrameNum)
{
    ui->groupBox_CurrentFile->setTitle(tr("Current file:")+" "+FileName);
    //=================================
    ui->progressBar_CurrentFile->setRange(0,FrameNum);
    ui->progressBar_CurrentFile->setValue(0);
    //=================================
    ui->label_FrameProgress_CurrentFile->setText(tr("0% · 0/%1").arg(FrameNum));
    ui->label_TimeRemain_CurrentFile->setText(tr("Remaining —"));
    ui->label_TimeCost_CurrentFile->setText(tr("Elapsed —"));
    ui->label_ETA_CurrentFile->setText(tr("ETA —"));
    //=================================
    TimeCost_CurrentFile = 0;
    TaskNumTotal_CurrentFile=FrameNum;
    TaskNumFinished_CurrentFile=0;
    NewTaskFinished_CurrentFile=false;
    ETA_CurrentFile=0;
    //=================================
    ui->groupBox_CurrentFile->setVisible(1);
    //=================================
    isStart_CurrentFile = true;
    return;
}
/*
停止处理当前文件
*/
void MainWindow::CurrentFileProgress_Stop()
{
    ui->groupBox_CurrentFile->setTitle(tr("Preparing…"));
    ui->progressBar_CurrentFile->setRange(0,1);
    ui->progressBar_CurrentFile->setValue(0);
    ui->label_FrameProgress_CurrentFile->setText(tr("—"));
    isStart_CurrentFile = false;
    return;
}
/*
进度条 进度+1
*/
void MainWindow::CurrentFileProgress_progressbar_Add()
{
    TaskNumFinished_CurrentFile++;
    NewTaskFinished_CurrentFile=true;
    ui->progressBar_CurrentFile->setValue(TaskNumFinished_CurrentFile);
    ui->label_FrameProgress_CurrentFile->setText(tr("%1% · %2/%3").arg(TaskNumTotal_CurrentFile ? qRound(100.0 * TaskNumFinished_CurrentFile / TaskNumTotal_CurrentFile) : 0).arg(TaskNumFinished_CurrentFile).arg(TaskNumTotal_CurrentFile));
}
/*
进度条 进度+片段時長
*/
void MainWindow::CurrentFileProgress_progressbar_Add_SegmentDuration(int SegmentDuration)
{
    TaskNumFinished_CurrentFile+=SegmentDuration;
    NewTaskFinished_CurrentFile=true;
    ui->progressBar_CurrentFile->setValue(TaskNumFinished_CurrentFile);
    ui->label_FrameProgress_CurrentFile->setText(tr("%1% · %2/%3").arg(TaskNumTotal_CurrentFile ? qRound(100.0 * TaskNumFinished_CurrentFile / TaskNumTotal_CurrentFile) : 0).arg(TaskNumFinished_CurrentFile).arg(TaskNumTotal_CurrentFile));
}
/*
进度条 进度+片段時長
*/
void MainWindow::CurrentFileProgress_progressbar_SetFinishedValue(int FinishedValue)
{
    TaskNumFinished_CurrentFile=FinishedValue;
    NewTaskFinished_CurrentFile=true;
    ui->progressBar_CurrentFile->setValue(TaskNumFinished_CurrentFile);
    ui->label_FrameProgress_CurrentFile->setText(tr("%1% · %2/%3").arg(TaskNumTotal_CurrentFile ? qRound(100.0 * TaskNumFinished_CurrentFile / TaskNumTotal_CurrentFile) : 0).arg(TaskNumFinished_CurrentFile).arg(TaskNumTotal_CurrentFile));
}
/*
监视文件夹内文件数量
*/
void MainWindow::CurrentFileProgress_WatchFolderFileNum(QString FolderPath)
{
    QStringList FilesNameList;
    do
    {
        if(FileProgressWatch_isEnabled==false||!AppQuitSleep(2300))return;
        if(file_isDirExist(FolderPath)==false)return;
        FilesNameList = file_getFileNames_in_Folder_nofilter(FolderPath);
        emit Send_CurrentFileProgress_progressbar_SetFinishedValue(FilesNameList.size());
    }
    while(!g_appQuitting.load(std::memory_order_relaxed));
}
/*
监视文件夹内文件数量
*/
void MainWindow::CurrentFileProgress_WatchFolderFileNum_Textbrower(QString SourceFile_fullPath,QString FolderPath,int TotalFileNum)
{
    QStringList FilesNameList;
    int OLD_num=0;
    int New_num=0;
    do
    {
        if(FileProgressWatch_isEnabled==false||!AppQuitSleep(2300))return;
        //==========
        if(file_isDirExist(FolderPath)==false)return;
        //=========
        New_num = file_getFileNames_in_Folder_nofilter(FolderPath).size();
        if(New_num!=OLD_num)
        {
            OLD_num=New_num;
            emit Send_TextBrowser_NewMessage(tr("File name:[")+SourceFile_fullPath+tr("]  Scale progress:[")+QString::number(New_num,10)+"/"+QString::number(TotalFileNum,10)+tr("] Frames"));
        }
    }
    while(!g_appQuitting.load(std::memory_order_relaxed));
}
